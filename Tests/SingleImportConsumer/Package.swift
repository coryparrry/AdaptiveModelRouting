// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SingleImportConsumer",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    dependencies: [.package(name: "AdaptiveModelRouting", path: "../..")],
    targets: [
        .target(name: "SingleImportConsumer", dependencies: [
            .product(name: "AdaptiveModelRouting", package: "AdaptiveModelRouting"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
