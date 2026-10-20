// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrossDropCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CrossDropCore", targets: ["CrossDropCore"]),
        .executable(name: "crossdrop-cli", targets: ["crossdrop-cli"]),
    ],
    targets: [
        .target(name: "CrossDropCore", path: "Sources/CrossDropCore"),
        .executableTarget(name: "crossdrop-cli", dependencies: ["CrossDropCore"], path: "Sources/crossdrop-cli"),
        .testTarget(name: "CrossDropCoreTests", dependencies: ["CrossDropCore"], path: "Tests/CrossDropCoreTests"),
    ]
)
