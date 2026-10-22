// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InsightsKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DuplicatesKit", targets: ["DuplicatesKit"]),
        .library(name: "ReportKit", targets: ["ReportKit"]),
    ],
    dependencies: [
        .package(path: "../SafetyKit"),
    ],
    targets: [
        .target(name: "DuplicatesKit", dependencies: [.product(name: "SafetyKit", package: "SafetyKit")]),
        .target(name: "ReportKit"),
        .testTarget(name: "DuplicatesKitTests", dependencies: ["DuplicatesKit", .product(name: "SafetyKit", package: "SafetyKit")]),
        .testTarget(name: "ReportKitTests", dependencies: ["ReportKit"]),
    ]
)
