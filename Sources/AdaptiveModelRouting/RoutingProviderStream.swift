import Foundation

/// Couples a provider stream to the producer task that actually owns its inference operation.
/// The producer must await its SDK/transport work rather than launch detached work and return early.
public struct RoutingProviderStream<Value: Sendable>: Sendable {
    let stream: AsyncThrowingStream<Value, any Error>
    private let finish: @MainActor () async -> (any Error)?

    /// Owns generation through producer exit, even when a cancelled consumer stops iterating sooner.
    @MainActor
    public init(
        bufferingPolicy: AsyncThrowingStream<Value, any Error>.Continuation.BufferingPolicy = .bufferingNewest(1),
        producer: @escaping @MainActor (AsyncThrowingStream<Value, any Error>.Continuation) async throws -> Void
    ) {
        let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: bufferingPolicy)
        let task = Task { @MainActor () -> (any Error)? in
            do {
                try Task.checkCancellation()
                try await producer(continuation)
                continuation.finish()
                return nil
            } catch {
                continuation.finish(throwing: error)
                return error
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        self.stream = stream
        finish = { task.cancel(); return await task.value }
    }

    /// Adapts legacy streams whose external producer lifetime remains the supplying app's responsibility.
    init(unowned stream: AsyncThrowingStream<Value, any Error>) {
        self.stream = stream
        finish = { nil }
    }

    /// Awaits actual producer exit and preserves errors that arrive after the stream consumer has cancelled.
    @MainActor
    func finishProducer() async -> (any Error)? { await finish() }
}
