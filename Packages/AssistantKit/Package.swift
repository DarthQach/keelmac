// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssistantKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AssistantKit", targets: ["AssistantKit"])],
    targets: [
        .target(name: "AssistantKit"),
        .testTarget(
            name: "AssistantKitTests",
            dependencies: ["AssistantKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
