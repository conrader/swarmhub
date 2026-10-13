import Foundation
import Testing
@testable import AgentApp

private let exportFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Documents/Torvli Grok Export")

/// Local-only (skipped without Konrad's export): each real bundle's effective look against the brief's table, by name.
/// No id is printed or stored; only names and words are compared.
@Suite struct AvatarRosterLocalTests {
    static let expected: [String: String] = [
        "Jarvis": "blob/black", "Infra": "cylinder/violet", "Finance Controller": "gem/yellow", "Reactor": "hex/orange", "DMT": "leaf/green",
        "Admin": "shield/blue", "Achilles": "shield/yellow", "Boppy": "blob/blue", "Botsilo": "cloud/blue", "Ermes": "tablet/green",
        "Vised": "wedge/red", "Doc": "teardrop/brown", "Plainsay": "hex/blue", "NetROAS": "tablet/gray", "Saldora": "tablet/brown",
        "Rapper": "blob/green"
    ]

    @Test(.enabled(if: FileManager.default.fileExists(atPath: exportFolder.appending(path: "index.json").path)))
    func realBundlesDeriveTheBriefsLooks() throws {
        let bundles = try GrokBundleLoader.load(from: exportFolder).filter { !($0.isGroup ?? false) }
        var seen: [String: String] = [:]
        for bundle in bundles {
            let mark = GrokAvatarMap.map(shape: bundle.avatar?.shape, colour: bundle.avatar?.colour, sourceID: bundle.sourceId)
            seen[bundle.name] = "\(mark.shape)/\(mark.colour)"
        }
        #expect(seen == Self.expected)
    }
}
