// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaptiveModelRouting",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AdaptiveModelRouting", targets: ["AdaptiveModelRouting"]),
    ],
    targets: [
        .target(name: "AdaptiveModelRouting"),
        .target(name: "RoutingExample", dependencies: ["AdaptiveModelRouting"], path: "Examples"),
        .target(name: "AppleRoutingExample", dependencies: ["AdaptiveModelRouting"], path: "AppleExamples"),
        .testTarget(name: "AdaptiveModelRoutingTests", dependencies: ["AdaptiveModelRouting", "RoutingExample"]),
    ],
    swiftLanguageModes: [.v6]
)
