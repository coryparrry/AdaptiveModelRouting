import Foundation

/// Transfers a provider's structured retry hint without coupling core routing to native SDK error types.
protocol RoutingRetryAfterProviding: Error {
    /// Supplies an absolute reset time; nil retains the ordinary bounded failure cooldown.
    var routingRetryAfter: Date? { get }
}
