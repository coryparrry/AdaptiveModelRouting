import Foundation

/// Lets a consenting app report one successful router use per process launch, using one shared instance.
@MainActor
public final class UsageReporter {
    private let version: String
    private let eligible: Bool
    private let report: @Sendable (String) async -> Void
    private var enabled = false
    private var attempted = false
    private var task: Task<Void, Never>?

    /// Uses the supplied HTTPS collector. The host app explicitly enables reporting after consent.
    public convenience init(packageVersion: String, collectorURL: URL) throws {
        guard packageVersion.wholeMatch(of: /(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})\.(?:0|[1-9][0-9]{0,3})/) != nil else {
            throw UsageReportingError.invalidVersion
        }
        let transport = try UsageTransport(collectorURL: collectorURL)
        self.init(packageVersion: packageVersion, eligible: Self.releaseEnvironment, report: transport.send)
    }

    /// Supplies a fake sender for tests of consent, eligibility, and one-shot behavior.
    init(packageVersion: String, eligible: Bool, report: @escaping @Sendable (String) async -> Void) {
        self.version = packageVersion
        self.eligible = eligible
        self.report = report
    }

    /// Enables reporting only when the app has consent, and cancels outstanding work on withdrawal.
    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { task?.cancel() }
    }

    /// Call after a successful foreground request. Sending is best-effort and never delays inference.
    public func recordSuccessfulUse() {
        guard eligible, enabled, !attempted else { return }
        attempted = true
        task = Task { [report, version] in
            guard !Task.isCancelled else { return }
            await report(version)
        }
    }

    /// Lets tests await the scheduled best-effort operation.
    func waitForReport() async { await task?.value }

    /// Gates normal production sends out of Debug and simulator builds.
    private static var releaseEnvironment: Bool {
#if DEBUG || targetEnvironment(simulator)
        false
#else
        // XCTest can run an optimized build too.
        NSClassFromString("XCTestCase") == nil
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
#endif
    }
}

/// Indicates invalid deployment configuration before a reporter sends anything.
public enum UsageReportingError: Error {
    case invalidVersion
    case invalidCollector
}
