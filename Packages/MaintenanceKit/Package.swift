// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaintenanceKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HelperShared", targets: ["HelperShared"]),
        .library(name: "HelperCore", targets: ["HelperCore"]),
        .library(name: "MaintenanceKit", targets: ["MaintenanceKit"]),
    ],
    dependencies: [
        .package(path: "../SafetyKit"),
    ],
    targets: [
        .target(name: "HelperShared", dependencies: [.product(name: "SafetyKit", package: "SafetyKit")]),
        .target(name: "HelperCore", dependencies: ["HelperShared", .product(name: "SafetyKit", package: "SafetyKit")]),
        .target(name: "MaintenanceKit", dependencies: ["HelperShared", .product(name: "SafetyKit", package: "SafetyKit")]),
        .testTarget(
            name: "MaintenanceKitTests",
            dependencies: ["HelperShared", "HelperCore", "MaintenanceKit", .product(name: "SafetyKit", package: "SafetyKit")],
            resources: [.copy("Fixtures")]
        ),
    ]
)
