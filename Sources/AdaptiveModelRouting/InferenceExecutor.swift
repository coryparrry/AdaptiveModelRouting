import Foundation

/// Executes the preferred lane once and preserves cancellation through model fallback.
public nonisolated enum InferenceExecutor {
    /// Retries only recognized temporary network failures; apps classify model-specific errors.
    public static func isRetryable(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable, .cannotLoadFromNetwork:
            return true
        default: return false
        }
    }

    /// Checks local capacity independently of model preference or learned latency.
    public static func fitsLocal(inputTokens: Int, localCapacity: Int, responseReserve: Int = 400) -> Bool {
        inputTokens >= 0 && responseReserve >= 0 && localCapacity >= responseReserve
            && inputTokens <= localCapacity - responseReserve
    }

    /// Enforces quality constraints and classifies each failure once before considering fallback.
    /// The classifier also observes terminal failures; each provider is attempted at most once.
    /// Unknown errors propagate by default; nil cloud results explicitly permit local fallback.
    @MainActor
    public static func respond<Value>(
        preferred: InferenceRoute, canUseLocalWhole: Bool,
        policy: RoutingPolicy = .automatic,
        shouldFallback: (InferenceRoute, any Error) -> Bool = { _, error in isRetryable(error) },
        cloud: () async throws -> Value?,
        onDevice: () async throws -> Value
    ) async throws -> Value? {
        try Task.checkCancellation()
        if preferred == .onDevice && policy != .cloudRequired {
            guard canUseLocalWhole else { return nil }
            do {
                let value = try await onDevice()
                try Task.checkCancellation()
                return value
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let retry = shouldFallback(.onDevice, error)
                try Task.checkCancellation()
                guard retry else { throw error }
                return try await finalAttempt(model: .cloud, shouldFallback: shouldFallback, operation: cloud)
            }
        }
        do {
            let value = try await cloud()
            try Task.checkCancellation()
            if let value { return value }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let retry = shouldFallback(.cloud, error)
            try Task.checkCancellation()
            guard retry, policy != .cloudRequired, canUseLocalWhole else { throw error }
        }
        try Task.checkCancellation()
        guard policy != .cloudRequired, canUseLocalWhole else { return nil }
        return try await finalAttempt(model: .onDevice, shouldFallback: shouldFallback, operation: onDevice)
    }

    /// Reports the final lane's health without retrying an already attempted provider.
    @MainActor
    private static func finalAttempt<Value>(
        model: InferenceRoute, shouldFallback: (InferenceRoute, any Error) -> Bool,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await operation()
            try Task.checkCancellation()
            return value
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            _ = shouldFallback(model, error)
            try Task.checkCancellation()
            throw error
        }
    }
}
