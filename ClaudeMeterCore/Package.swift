// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeMeterCore", targets: ["ClaudeMeterCore"])
    ],
    targets: [
        .target(
            name: "ClaudeMeterCore",
            path: "Sources/ClaudeMeterCore"
        ),
        .testTarget(
            name: "ClaudeMeterCoreTests",
            dependencies: ["ClaudeMeterCore"],
            path: "Tests/ClaudeMeterCoreTests"
        )
    ]
)
