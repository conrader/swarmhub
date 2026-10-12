// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentApp", targets: ["AgentApp"])],
    targets: [
        .executableTarget(
            name: "AgentApp",
            path: ".",
            exclude: ["Tests", "scripts", "docs", "README.md", "BRIEF.md", "BRIEF-visual.md", "BRIEF-simplify.md", "BRIEF-parity.md"],
            sources: ["Sources/AgentApp"],
            resources: [.copy("Resources/Avatars")]
        ),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp"], path: "Tests/AgentAppTests")
    ]
)
