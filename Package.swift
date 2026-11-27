// swift-tools-version: 6.0
import Foundation
import PackageDescription

let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("docs")
let otherDocs = (try? FileManager.default.contentsOfDirectory(atPath: docs.path))?.filter { $0 != "releases" }.map { "docs/" + $0 } ?? []

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
            // Output folders too: dist/ holds packaged .app bundles whose Sparkle nibs/lproj SwiftPM would treat as resources
            // (hidden .build* folders, incl. .build-release, are skipped by SwiftPM anyway). Guarded by PackageManifestTests.
            exclude: ["Tests", "scripts", "Vendor", "dist", "Apps", "HerdrWorkspace", "README.md"] + otherDocs,
            sources: ["Sources/AgentApp"],
            resources: [.copy("Resources/Avatars"), .copy("Resources/Samples"), .copy("Resources/AppIcon/ThemeIcons"), .copy("docs/releases")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]
        ),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp", "BotAvatarsKit"], path: "Tests/AgentAppTests")
    ]
)
