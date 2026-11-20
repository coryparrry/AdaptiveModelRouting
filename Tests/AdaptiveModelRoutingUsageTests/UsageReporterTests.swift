import Foundation
import XCTest
@testable import AdaptiveModelRoutingUsage

/// Holds fixture reports without any HTTP requests or persistent identity.
private actor CapturedReports {
    private(set) var versions: [String] = []

    /// Records the version received by the configured reporter.
    func append(_ version: String) { versions.append(version) }
}

/// Exercises eligibility, consent, and the version-only payload independently of the host application.
@MainActor
final class UsageReporterTests: XCTestCase {
    /// Reports only the first opted-in success and stays silent before consent.
    func testConsentAndOneReportPerLaunch() async {
        let capture = CapturedReports()
        let reporter = UsageReporter(packageVersion: "0.2.0", eligible: true) { await capture.append($0) }
        reporter.recordSuccessfulUse()
        await reporter.waitForReport()
        var captured = await capture.versions
        XCTAssertTrue(captured.isEmpty)

        reporter.setEnabled(true)
        reporter.recordSuccessfulUse()
        reporter.recordSuccessfulUse()
        await reporter.waitForReport()
        reporter.setEnabled(false)
        reporter.setEnabled(true)
        reporter.recordSuccessfulUse()
        await reporter.waitForReport()
        captured = await capture.versions
        XCTAssertEqual(captured, ["0.2.0"])
    }

    /// Stops unsent work when consent is withdrawn and suppresses ineligible build environments.
    func testWithdrawalAndEnvironmentGate() async {
        let capture = CapturedReports()
        let eligible = UsageReporter(packageVersion: "0.2.0", eligible: true) { await capture.append($0) }
        let ineligible = UsageReporter(packageVersion: "0.2.0", eligible: false) { await capture.append($0) }
        for reporter in [eligible, ineligible] {
            reporter.setEnabled(true)
            reporter.recordSuccessfulUse()
            reporter.setEnabled(false)
            await reporter.waitForReport()
        }
        let versions = await capture.versions
        XCTAssertTrue(versions.isEmpty)
    }

    /// Rejects configurations that would send to HTTP or include a query or credentials.
    func testRejectsInvalidCollectorURL() {
        for string in ["http://worker.example/v1/used", "https://worker.example/other",
                       "https://worker.example/v1/used?identity=forbidden",
                       "https://user@worker.example/v1/used"] {
            XCTAssertThrowsError(try UsageTransport(collectorURL: URL(string: string)!))
        }
    }

    /// Sends a version-only body over HTTPS and excludes app-specific cookie handling.
    func testRequestContainsOnlyVersion() throws {
        let url = URL(string: "https://worker.example/v1/used")!
        let transport = try UsageTransport(collectorURL: url)
        let request = transport.request(for: "0.2.0")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.httpBody, Data("0.2.0".utf8))
    }
}
