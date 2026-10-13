import Foundation
import Testing
@testable import AgentApp

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../Fixtures/avatar_migration_store.json").standardizedFileURL
private func gid(_ suffix: String) -> String { "00000000-0000-4000-8000-00000000" + suffix }

/// P15 item 8: lazy, additive migration of what the P6 importer provably wrote (synthetic fixture).
@Suite struct AvatarMigrationTests {
    private func load() throws -> (StoreFile, [String: Bot]) {
        let file = try JSONDecoder().decode(StoreFile.self, from: Data(contentsOf: fixture))
        return (file, Dictionary(uniqueKeysWithValues: file.bots.map { ($0.name, $0) }))
    }

    @Test func importerPairsBecomeMarks() throws {
        let (_, bots) = try load()
        #expect(bots["Clay black"]?.avatarMark == AvatarMark(shape: "blob", colour: "black"))
        #expect(bots["Clay shield blue"]?.avatarMark == AvatarMark(shape: "shield", colour: "blue"))
        #expect(bots["Clay shield yellow"]?.avatarMark == AvatarMark(shape: "shield", colour: "yellow"))
        #expect(bots["Clay without accent"]?.avatarMark == AvatarMark(shape: "cylinder", colour: GrokDefaultLook.mark(for: gid("a012")).colour))
        #expect(bots["Colour face violet"]?.avatarMark == AvatarMark(shape: GrokDefaultLook.mark(for: gid("a004")).shape, colour: "violet"))
        #expect(bots["Fallback face"]?.avatarMark == GrokDefaultLook.mark(for: gid("a005")))
        for name in ["Clay black", "Colour face violet", "Fallback face"] { #expect(bots[name]?.avatarMarkMigrated == true) }
    }

    @Test func picksAfterImportAndNonGrokBotsStayClassic() throws {
        let (_, bots) = try load()
        #expect(bots["Picked after import"]?.avatarLook == .classic(.fox))
        #expect(bots["Face not the fallback"]?.avatarLook == .classic(.faceSun))
        #expect(bots["Local bot"]?.avatarLook == .classic(.faceSky))
        #expect(bots["Local bot"]?.avatarMarkMigrated == false)
    }

    @Test func storedWordsAreKeptVerbatimAndResolvedPerField() throws {
        let (_, bots) = try load()
        let unknown = try #require(bots["Unknown words"])
        #expect(unknown.avatarMark == AvatarMark(shape: "Blob", colour: "pink") && !unknown.avatarMarkMigrated)
        let derived = GrokDefaultLook.mark(for: gid("a009"))
        #expect(unknown.avatarLook == .mark(shape: derived.shape, colour: AvatarColour(rawValue: derived.colour)!))
        #expect(bots["Stored mark"]?.avatarLook == .mark(shape: "star", colour: .cyan))
    }

    @Test func malformedMarkDecodesAndCostsNothing() throws {
        let (file, bots) = try load()
        #expect(file.bots.count == 12 && file.version == 2)
        let bot = try #require(bots["Malformed mark"])
        #expect(bot.avatarMark == nil && bot.avatarName == .faceMint && bot.avatarLook == .classic(.faceMint))
    }

    @Test func reEncodingIsAdditiveAndKeepsLegacyFields() throws {
        let (file, _) = try load()
        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as! [String: Any]
        #expect(encoded["version"] as? Int == 2)
        let before = (original["bots"] as! [[String: Any]]), after = (encoded["bots"] as! [[String: Any]])
        for (old, new) in zip(before, after) {
            #expect(old["avatarName"] as? String == new["avatarName"] as? String)
            #expect(old["accentColor"] as? String == new["accentColor"] as? String)
        }
        let clay = try #require(after.first { $0["name"] as? String == "Clay black" })
        #expect(clay["avatarMark"] as? [String: String] == ["shape": "blob", "colour": "black"])
        #expect(after.first { $0["name"] as? String == "Local bot" }?["avatarMark"] == nil)
        // A pre-P15 decoder ignores the extra key: every avatarName still decodes as one of the 21 cases.
        #expect(after.allSatisfy { BotAvatarName(rawValue: $0["avatarName"] as? String ?? "") != nil })
        #expect(BotAvatarName.allCases.count == 21 && BotAvatarName.allCases.first == .faceCoral && BotAvatarName.allCases.last == .pebble)
    }

    @Test @MainActor func loadingDoesNotSave() throws {
        let url = temporaryStore()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: url)
        let before = try Data(contentsOf: url)
        let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(store.bots.first { $0.name == "Clay black" }?.avatarMarkMigrated == true)
        #expect(try Data(contentsOf: url) == before)
    }
}
