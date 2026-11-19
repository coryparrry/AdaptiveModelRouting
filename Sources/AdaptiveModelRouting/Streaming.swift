import Foundation

/// Carries cumulative snapshots rather than deltas, so a slow consumer can safely coalesce updates.
public nonisolated enum RoutingStreamEvent<Value: Sendable>: Sendable {
    case selected(RoutingDecision)
    case update(Value, route: InferenceRoute)
    case completed(RoutingResult<Value>)
}

/// Bridges request execution into a bounded stream and propagates consumer termination to provider work.
@MainActor
enum RoutingStreamFactory {
    /// Keeps at most eight events; the completed event always includes the last full snapshot and diagnostics.
    static func make<Value: Sendable>(
        operation: @escaping @MainActor (AsyncThrowingStream<RoutingStreamEvent<Value>, any Error>.Continuation)
            async throws -> RoutingResult<Value>
    ) -> AsyncThrowingStream<RoutingStreamEvent<Value>, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let producer = Task { @MainActor in
                do {
                    try Task.checkCancellation()
                    let result = try await operation(continuation)
                    try Task.checkCancellation()
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

extension AdaptiveRouter {
    /// Streams cumulative provider snapshots; fallback is forbidden after the first published snapshot.
    public func stream<Value: Sendable>(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init(), deadline: RoutingDeadline? = nil,
        shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        onAttempt: ((RoutingAttempt) -> Void)? = nil,
        cloud: @escaping @MainActor () async throws -> AsyncThrowingStream<Value, any Error>?,
        onDevice: @escaping @MainActor () async throws -> AsyncThrowingStream<Value, any Error>
    ) -> AsyncThrowingStream<RoutingStreamEvent<Value>, any Error> {
        streamOwned(inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            policy: policy, workload: workload, availability: availability, deadline: deadline,
            shouldFallback: shouldFallback, onAttempt: onAttempt,
            cloud: {
                guard let stream = try await cloud() else { return nil }
                return RoutingProviderStream(unowned: stream)
            }, onDevice: { RoutingProviderStream(unowned: try await onDevice()) })
    }

    /// Tracks actual producer exit so timeout/cancellation cannot start overlapping secondary inference.
    /// Providers must await all generation work inside RoutingProviderStream's producer closure.
    public func streamOwned<Value: Sendable>(
        inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy = .automatic, workload: RoutingWorkload = .init(),
        availability: RoutingAvailability = .init(), deadline: RoutingDeadline? = nil,
        shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool = { _, error in InferenceExecutor.isRetryable(error) },
        onAttempt: ((RoutingAttempt) -> Void)? = nil,
        cloud: @escaping @MainActor () async throws -> RoutingProviderStream<Value>?,
        onDevice: @escaping @MainActor () async throws -> RoutingProviderStream<Value>
    ) -> AsyncThrowingStream<RoutingStreamEvent<Value>, any Error> {
        RoutingStreamFactory.make { continuation in
            try await self.withRequest(deadline: deadline, onAttempt: onAttempt) { context in
                try await self.performStreaming(context: context, inputTokens: inputTokens,
                    localContextCapacity: localContextCapacity, policy: policy, workload: workload,
                    availability: availability, shouldFallback: shouldFallback, continuation: continuation,
                    cloud: cloud, onDevice: onDevice)
            }
        }
    }

    /// Shares profile measurement, diagnostics and hard policy enforcement with non-streaming requests.
    func performStreaming<Value: Sendable>(context: RoutingRequestContext, inputTokens: Int, localContextCapacity: Int,
        policy: RoutingPolicy, workload: RoutingWorkload, availability: RoutingAvailability,
        calibrationIdentifier: String? = nil, shouldFallback: @escaping @MainActor (InferenceRoute, any Error) -> Bool,
        cloudPermission: @escaping @MainActor (Bool) -> Bool = { _ in true },
        localPermission: @escaping @MainActor () -> Bool = { true },
        continuation: AsyncThrowingStream<RoutingStreamEvent<Value>, any Error>.Continuation,
        cloud: @escaping @MainActor () async throws -> RoutingProviderStream<Value>?,
        onDevice: @escaping @MainActor () async throws -> RoutingProviderStream<Value>
    ) async throws -> RoutingResult<Value> {
        var published = false
        return try await performDetailed(context: context, inputTokens: inputTokens, localContextCapacity: localContextCapacity,
            policy: policy, workload: workload, availability: availability, calibrationIdentifier: calibrationIdentifier,
            onDecision: { continuation.yield(.selected($0)) }, canFallback: { !published },
            shouldFallback: shouldFallback, cloudPermission: cloudPermission, localPermission: localPermission,
            onProbeFallback: { value, route in
                if case .terminated = continuation.yield(.update(value, route: route)) { throw CancellationError() }
                published = true
            }, cloud: { scope, isCalibration in
                guard let source = try await cloud() else { return nil }
                return try await self.consume(source, route: .cloud, context: scope,
                    continuation: isCalibration ? nil : continuation, didPublish: { published = true })
            }, onDevice: { scope, isCalibration in
                let source = try await onDevice()
                guard let value = try await self.consume(source, route: .onDevice, context: scope,
                    continuation: isCalibration ? nil : continuation, didPublish: { published = true }) else { throw RoutingRequestError.emptyStream }
                return value
            })
    }

    /// Publishes only while the request is active and returns the final cumulative snapshot for result metadata.
    private func consume<Value: Sendable>(_ source: RoutingProviderStream<Value>, route: InferenceRoute,
        context: RoutingRequestContext,
        continuation: AsyncThrowingStream<RoutingStreamEvent<Value>, any Error>.Continuation?,
        didPublish: () -> Void
    ) async throws -> Value? {
        let result: Result<Value?, any Error>
        var cancelProducer = false
        do {
            var last: Value?
            for try await value in source.stream {
                try context.checkActive()
                if let continuation {
                    if case .terminated = continuation.yield(.update(value, route: route)) { throw CancellationError() }
                    didPublish()
                }
                last = value
            }
            result = .success(last)
        } catch {
            if route == .cloud { recordRetryDeadline(error) }
            cancelProducer = true
            result = .failure(error)
        }
        // A cancelled iterator can finish before a noncooperative producer returns its server reset date.
        let producerError = await source.finishProducer(cancelling: cancelProducer)
        if let producerError, route == .cloud { recordRetryDeadline(producerError) }
        let value = try result.get()
        try context.checkActive()
        if let producerError { throw producerError }
        return value
    }
}
