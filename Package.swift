// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AdaptiveModelRouting",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AdaptiveModelRouting", targets: ["AdaptiveModelRouting"]),
        .library(name: "AdaptiveFoundationModels", targets: ["AdaptiveFoundationModels"]),
    ],
    targets: [
        .target(name: "AdaptiveModelRouting"),
        .target(name: "AdaptiveFoundationModels", dependencies: ["AdaptiveModelRouting"]),
        .target(name: "RoutingExample", dependencies: ["AdaptiveModelRouting"], path: "Examples"),
        .target(name: "AppleRoutingExample", dependencies: ["AdaptiveFoundationModels"], path: "AppleExamples"),
        .testTarget(name: "AdaptiveModelRoutingTests", dependencies: ["AdaptiveModelRouting", "RoutingExample"]),
        .testTarget(name: "AdaptiveFoundationModelsTests", dependencies: ["AdaptiveFoundationModels"]),
    ],
    swiftLanguageModes: [.v6]
)
