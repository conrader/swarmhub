// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentApp", targets: ["AgentApp"])],
    targets: [
        // Vendored, pinned BotAvatarsKit (MIT, see Vendor/BotAvatarsKit/VENDORED.md); Swift 5 mode, the app stays Swift 6.
        .target(
            name: "BotAvatarsKit",
            path: "Vendor/BotAvatarsKit/Sources/BotAvatarsKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AgentApp",
            dependencies: ["BotAvatarsKit"],
            path: ".",
            exclude: ["Tests", "scripts", "docs", "Vendor", "README.md", "BRIEF.md", "BRIEF-visual.md", "BRIEF-simplify.md", "BRIEF-parity.md"],
            sources: ["Sources/AgentApp"],
            resources: [.copy("Resources/Avatars")]
        ),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp", "BotAvatarsKit"], path: "Tests/AgentAppTests")
    ]
)
