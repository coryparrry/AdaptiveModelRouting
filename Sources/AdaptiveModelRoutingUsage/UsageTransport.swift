import Foundation

/// Sends one version-only report to the host app's configured HTTPS collector.
struct UsageTransport: Sendable {
    private let collectorURL: URL

    /// Accepts the HTTPS usage endpoint and rejects configuration with credentials or query parameters.
    init(collectorURL: URL) throws {
        guard let components = URLComponents(url: collectorURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.path == "/v1/used", components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw UsageReportingError.invalidCollector
        }
        self.collectorURL = collectorURL
    }

    /// Builds a request whose body contains only the library version.
    func request(for version: String) -> URLRequest {
        var request = URLRequest(url: collectorURL, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue("AdaptiveModelRoutingUsage", forHTTPHeaderField: "User-Agent")
        request.setValue("*", forHTTPHeaderField: "Accept-Language")
        request.httpBody = Data(version.utf8)
        request.httpShouldHandleCookies = false
        return request
    }

    /// Reports asynchronously without redirecting, storing credentials, or retrying in the app.
    func send(_ version: String) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            try Task.checkCancellation()
            _ = try await session.data(for: request(for: version))
        } catch {
            // Reporting failure never affects the app's response.
        }
    }
}

/// Keeps usage reports on the configured collector origin.
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    /// Declines redirects before any report can be resent to another address.
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
