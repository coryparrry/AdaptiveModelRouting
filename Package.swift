// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaptiveModelRouting",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AdaptiveModelRouting", targets: ["AdaptiveModelRouting"]),
        .library(name: "AdaptiveModelRoutingUsage", targets: ["AdaptiveModelRoutingUsage"]),
    ],
    targets: [
        .target(name: "AdaptiveModelRouting"),
        .target(name: "AdaptiveModelRoutingUsage"),
        .target(name: "RoutingExample", dependencies: ["AdaptiveModelRouting"], path: "Examples"),
        .target(name: "AppleRoutingExample", dependencies: ["AdaptiveModelRouting"], path: "AppleExamples"),
        .testTarget(name: "AdaptiveModelRoutingTests", dependencies: ["AdaptiveModelRouting", "RoutingExample"]),
        .testTarget(name: "AdaptiveModelRoutingUsageTests", dependencies: ["AdaptiveModelRoutingUsage"]),
    ],
    swiftLanguageModes: [.v6]
)
