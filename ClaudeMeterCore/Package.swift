// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeMeterCore", targets: ["ClaudeMeterCore"]),
        .library(name: "ClaudeMeterProviders", targets: ["ClaudeMeterProviders"]),
    ],
    targets: [
        .target(
            name: "ClaudeMeterCore",
            path: "Sources/ClaudeMeterCore"
        ),
        .target(
            name: "ClaudeMeterProviders",
            dependencies: ["ClaudeMeterCore"],
            path: "Sources/ClaudeMeterProviders"
        ),
        .testTarget(
            name: "ClaudeMeterCoreTests",
            dependencies: ["ClaudeMeterCore"],
            path: "Tests/ClaudeMeterCoreTests"
        ),
        .testTarget(
            name: "ClaudeMeterProvidersTests",
            dependencies: ["ClaudeMeterCore", "ClaudeMeterProviders"],
            path: "Tests/ClaudeMeterProvidersTests"
        ),
    ]
)
