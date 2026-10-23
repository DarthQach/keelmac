// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectsKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ProjectsKit", targets: ["ProjectsKit"])],
    dependencies: [.package(path: "../SafetyKit")],
    targets: [
        .target(name: "ProjectsKit", dependencies: [.product(name: "SafetyKit", package: "SafetyKit")]),
        .testTarget(name: "ProjectsKitTests", dependencies: ["ProjectsKit", .product(name: "SafetyKit", package: "SafetyKit")]),
    ]
)
