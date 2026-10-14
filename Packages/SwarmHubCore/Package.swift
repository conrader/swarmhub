// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwarmHubCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "SwarmHubCore", targets: ["SwarmHubCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "SwarmHubCore", dependencies: ["CSQLite"]),
        .testTarget(name: "SwarmHubCoreTests", dependencies: ["SwarmHubCore"])
    ]
)
