// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentApp", targets: ["AgentApp"])],
    dependencies: [
        .package(path: "Packages/SwarmHubCore"),
        .package(path: "Packages/SwarmHubCoordination"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Vendored, pinned BotAvatarsKit (MIT, see Vendor/BotAvatarsKit/VENDORED.md); Swift 5 mode, the app stays Swift 6.
        .target(
            name: "BotAvatarsKit",
            path: "Vendor/BotAvatarsKit/Sources/BotAvatarsKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentApp",
            dependencies: ["BotAvatarsKit", .product(name: "Sparkle", package: "Sparkle"), .product(name: "SwarmHubCore", package: "SwarmHubCore"), .product(name: "SwarmHubCoordination", package: "SwarmHubCoordination")],
            path: ".",
            // Output folders too: dist/ holds packaged .app bundles whose Sparkle nibs/lproj SwiftPM would treat as resources
            // (hidden .build* folders, incl. .build-release, are skipped by SwiftPM anyway). Guarded by PackageManifestTests.
            exclude: ["Tests", "scripts", "docs", "Vendor", "dist", "briefs", "Apps", "Packages", "README.md"],
            sources: ["Sources/AgentApp"],
            resources: [.copy("Resources/Avatars"), .copy("Resources/BotManager"), .copy("Resources/Skills"), .copy("Resources/AppIcon/ThemeIcons")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp", "BotAvatarsKit"], path: "Tests/AgentAppTests")
    ]
)
