// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScanKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .executable(name: "scanbench", targets: ["scanbench"]),
    ],
    targets: [
        .target(name: "ScanKit"),
        .executableTarget(name: "scanbench", dependencies: ["ScanKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
    ]
)
