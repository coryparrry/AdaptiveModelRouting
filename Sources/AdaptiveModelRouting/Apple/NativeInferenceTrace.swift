#if canImport(FoundationModels)
import Foundation
import OSLog

/// Emits content-free native invocation boundaries when a developer enables unified debug logging.
@available(iOS 27.0, macOS 27.0, *)
final class NativeInferenceTrace {
    private static let logger = Logger(subsystem: "AdaptiveModelRouting", category: "NativeInference")
    private let identifier = UUID().uuidString
    private var finished = false
    private let route: String
    private let started = ContinuousClock.now

    /// Logs immediately before the native generation API, without recording prompts or generated values.
    init(route: InferenceRoute, format: String) {
        self.route = route.rawValue
        let identifier = self.identifier
        let route = self.route
        Self.logger.debug("native-start id=\(identifier, privacy: .public) route=\(route, privacy: .public) format=\(format, privacy: .public)")
    }

    /// Matches the native operation's exit without changing its output, failure or cancellation handling.
    func finish(succeeded: Bool) {
        guard !finished else { return }
        finished = true
        let duration = started.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let identifier = self.identifier
        let route = self.route
        Self.logger.debug("native-finish id=\(identifier, privacy: .public) route=\(route, privacy: .public) success=\(succeeded, privacy: .public) seconds=\(seconds, privacy: .public)")
    }

    /// Closes a trace even when cancellation prevents the owned producer from entering its body.
    deinit { finish(succeeded: false) }

}
#endif
