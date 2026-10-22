// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppsKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AppsKit", targets: ["AppsKit"])],
    dependencies: [.package(path: "../SafetyKit")],
    targets: [
        .target(name: "AppsKit", dependencies: ["SafetyKit"]),
        .testTarget(name: "AppsKitTests", dependencies: ["AppsKit", "SafetyKit"]),
    ]
)
