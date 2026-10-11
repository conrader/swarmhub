// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentApp",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "AgentApp", targets: ["AgentApp"])],
    targets: [
        .executableTarget(name: "AgentApp", path: "Sources/AgentApp"),
        .testTarget(name: "AgentAppTests", dependencies: ["AgentApp"], path: "Tests/AgentAppTests")
    ]
)
