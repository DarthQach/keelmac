// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetricsKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MetricsKit", targets: ["MetricsKit"])],
    targets: [
        .target(
            name: "MetricsKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .testTarget(
            name: "MetricsKitTests",
            dependencies: ["MetricsKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
