// swift-tools-version: 6.2
import PackageDescription

// Layers, lowest first. A module imports only modules above it in this list.
//   MeterDomain   values and pure rules
//   MeterPlatform operating-system adapters (HTTP, Keychain, files, processes, logs)
//   Provider*     one module per usage source
//   MeterApp      settings, refresh lifecycle, presentation models
//   MeterUI       SwiftUI views, status item, windows
// The Xcode app target in App/ links MeterUI and Sparkle.

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let providers = ["ProviderClaude", "ProviderCodex", "ProviderCursor", "ProviderGrok"]

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MeterUI", targets: ["MeterUI"])
    ],
    targets: [
        .target(name: "MeterDomain", swiftSettings: strictSettings),
        .target(
            name: "MeterPlatform",
            dependencies: ["MeterDomain"],
            swiftSettings: strictSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "ProviderClaude",
            dependencies: ["MeterDomain", "MeterPlatform"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "ProviderCodex",
            dependencies: ["MeterDomain", "MeterPlatform"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "ProviderCursor",
            dependencies: ["MeterDomain", "MeterPlatform"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "ProviderGrok",
            dependencies: ["MeterDomain", "MeterPlatform"],
            swiftSettings: strictSettings
        ),
        .target(
            name: "MeterApp",
            dependencies: ["MeterDomain", "MeterPlatform"] + providers.map { .target(name: $0) },
            swiftSettings: strictSettings
        ),
        .target(
            name: "MeterUI",
            dependencies: ["MeterDomain", "MeterApp"],
            resources: [.copy("Resources/Fonts"), .process("Resources/Images")],
            swiftSettings: strictSettings
        ),

        // Fakes and fixtures shared by test targets. Never linked into the app.
        .target(
            name: "MeterTestSupport",
            dependencies: ["MeterDomain", "MeterPlatform"],
            path: "Tests/MeterTestSupport",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MeterDomainTests",
            dependencies: ["MeterDomain", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MeterPlatformTests",
            dependencies: ["MeterPlatform", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ProviderClaudeTests",
            dependencies: ["ProviderClaude", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ProviderCodexTests",
            dependencies: ["ProviderCodex", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ProviderCursorTests",
            dependencies: ["ProviderCursor", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "ProviderGrokTests",
            dependencies: ["ProviderGrok", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MeterAppTests",
            dependencies: ["MeterApp", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MeterUITests",
            dependencies: ["MeterUI", "MeterTestSupport"],
            swiftSettings: strictSettings
        ),
    ]
)
