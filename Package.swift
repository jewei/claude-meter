// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeterWorkspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeMeter", targets: ["ClaudeMeter"]),
        .library(name: "ClaudeMeterWidget", targets: ["ClaudeMeterWidget"]),
    ],
    dependencies: [
        .package(path: "ClaudeMeterCore")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeMeter",
            dependencies: [
                .product(name: "ClaudeMeterCore", package: "ClaudeMeterCore"),
                .product(name: "ClaudeMeterProviders", package: "ClaudeMeterCore"),
            ],
            path: "ClaudeMeter",
            exclude: [
                "Assets.xcassets",
                "ClaudeMeter.entitlements",
                "Fonts",
                "Info.plist",
            ]
        ),
        .target(
            name: "ClaudeMeterWidget",
            dependencies: [
                .product(name: "ClaudeMeterCore", package: "ClaudeMeterCore")
            ],
            path: "ClaudeMeterWidget",
            exclude: [
                "ClaudeMeterWidget.entitlements",
                "ClaudeMeterWidget-Info.plist",
            ]
        ),
    ]
)
