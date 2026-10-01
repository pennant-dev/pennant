// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pennant",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PennantCore", targets: ["PennantCore"]),
        .library(name: "PennantHostKit", targets: ["PennantHostKit"]),
        .library(name: "PennantClientKit", targets: ["PennantClientKit"]),
        .library(name: "PennantUI", targets: ["PennantUI"]),
        .executable(name: "pennant-host", targets: ["PennantHost"]),
        .executable(name: "pennant", targets: ["PennantCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
    ],
    targets: [
        // System SQLite (FTS5 is enabled in Apple's build).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // Cross-platform models, task state machine, event and command protocol.
        .target(name: "PennantCore"),

        // macOS host: runtime, memory, skills, desktop control, tools, inference, API server.
        .target(
            name: "PennantHostKit",
            dependencies: [
                "PennantCore",
                "CSQLite",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "PennantHost",
            dependencies: ["PennantHostKit"],
            exclude: ["Info.plist", "AppIcon.icns", "PennantHost.entitlements"],
            linkerSettings: [
                // Embed an Info.plist so macOS can show usage descriptions and attribute privacy grants
                // to `dev.pennant.host` when the binary runs on its own (launchd).
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/Sources/PennantHost/Info.plist"]),
            ]
        ),

        // Client-side connection, cache, and view models shared by the Mac and iPhone apps.
        .target(name: "PennantClientKit", dependencies: ["PennantCore"]),
        .target(
            name: "PennantUI",
            dependencies: ["PennantClientKit", "PennantCore", .product(name: "MarkdownUI", package: "swift-markdown-ui")],
            // Brand marks for the MCP marketplace (BrandIcons.xcassets; see Scripts/fetch-brand-icons.swift).
            resources: [.process("Resources")],
            // The approval card plays video: AVKit must be linked, not only imported, or the player's classes
            // are missing at runtime.
            linkerSettings: [.linkedFramework("AVKit"), .linkedFramework("AVFoundation")]
        ),

        // Small terminal client for scripting and diagnostics.
        .executableTarget(name: "PennantCLI", dependencies: ["PennantClientKit", "PennantCore"]),

        .testTarget(name: "PennantCoreTests", dependencies: ["PennantCore"]),
        .testTarget(name: "PennantHostKitTests", dependencies: ["PennantHostKit", "PennantClientKit"]),
        .testTarget(name: "PennantUITests", dependencies: ["PennantUI", "PennantCore", "PennantClientKit"]),
    ]
)
