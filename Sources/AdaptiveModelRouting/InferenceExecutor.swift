import Foundation

/// Executes the preferred lane once and preserves cancellation through model fallback.
public nonisolated enum InferenceExecutor {
    /// Checks local capacity independently of model preference or learned latency.
    public static func fitsLocal(inputTokens: Int, localCapacity: Int, responseReserve: Int = 400) -> Bool {
        inputTokens >= 0 && responseReserve >= 0 && localCapacity >= responseReserve
            && inputTokens <= localCapacity - responseReserve
    }

    /// Returns nil when cloud is unavailable and the caller must split oversized local input.
    @MainActor
    public static func respond<Value>(
        preferred: InferenceRoute, canUseLocalWhole: Bool,
        cloud: () async throws -> Value?,
        onDevice: () async throws -> Value
    ) async throws -> Value? {
        try Task.checkCancellation()
        if preferred == .onDevice {
            guard canUseLocalWhole else { return nil }
            do {
                let value = try await onDevice()
                try Task.checkCancellation()
                return value
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                let value = try await cloud()
                try Task.checkCancellation()
                return value
            }
        }
        do {
            let value = try await cloud()
            try Task.checkCancellation()
            if let value { return value }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard canUseLocalWhole else { throw error }
        }
        try Task.checkCancellation()
        guard canUseLocalWhole else { return nil }
        let value = try await onDevice()
        try Task.checkCancellation()
        return value
    }
}
