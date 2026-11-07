// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RoutingDemo",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "RoutingDemo", targets: ["RoutingDemo"])],
    dependencies: [.package(path: "..")],
    targets: [
        .target(name: "RoutingDemoSupport", dependencies: [.product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting")]),
        .executableTarget(name: "RoutingDemo", dependencies: ["RoutingDemoSupport"]),
        .testTarget(name: "RoutingDemoTests", dependencies: ["RoutingDemoSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
