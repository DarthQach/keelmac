// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CleanKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CleanKit", targets: ["CleanKit"])],
    dependencies: [.package(path: "../SafetyKit")],
    targets: [
        .target(
            name: "CleanKit",
            dependencies: [.product(name: "SafetyKit", package: "SafetyKit")],
            resources: [.copy("Resources/cleanup-rules.json")]
        ),
        .testTarget(name: "CleanKitTests", dependencies: ["CleanKit", .product(name: "SafetyKit", package: "SafetyKit")]),
    ]
)
