// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafetyKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SafetyKit", targets: ["SafetyKit"])],
    targets: [
        .target(name: "SafetyKit"),
        .testTarget(name: "SafetyKitTests", dependencies: ["SafetyKit"]),
    ]
)
