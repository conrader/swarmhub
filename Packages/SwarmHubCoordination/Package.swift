// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwarmHubCoordination", platforms: [.macOS(.v14), .iOS(.v18)],
    products: [.library(name: "SwarmHubCoordination", targets: ["SwarmHubCoordination"])],
    targets: [.target(name: "SwarmHubCoordination"),
              .testTarget(name: "SwarmHubCoordinationTests", dependencies: ["SwarmHubCoordination"])])
