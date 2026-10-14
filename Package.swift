// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentApp", targets: ["AgentApp"])],
    dependencies: [
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
            dependencies: ["BotAvatarsKit", .product(name: "Sparkle", package: "Sparkle")],
            path: ".",
            exclude: ["Tests", "scripts", "docs", "Vendor", "README.md", "BRIEF.md", "BRIEF-visual.md", "BRIEF-simplify.md", "BRIEF-parity.md"],
            sources: ["Sources/AgentApp"],
            resources: [.copy("Resources/Avatars"), .copy("Resources/BotManager")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp", "BotAvatarsKit"], path: "Tests/AgentAppTests")
    ]
)
