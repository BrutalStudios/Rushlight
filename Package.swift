// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Rushlight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RushlightCore",
            path: "Sources/RushlightCore"
        ),
        .executableTarget(
            name: "Rushlight",
            dependencies: ["RushlightCore"],
            path: "Sources/Rushlight"
        ),
        .testTarget(
            name: "RushlightCoreTests",
            dependencies: ["RushlightCore"],
            path: "Tests/RushlightCoreTests"
        ),
    ]
)
