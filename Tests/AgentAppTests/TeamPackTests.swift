import Foundation
import Testing
@testable import AgentApp

@MainActor struct TeamPackTests {
    private func store() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    @Test func shareGroupDefinitionsAndRecoverWriteFailure() throws {
        let source = store(), destination = store()
        let scout = Bot(name: "Scout", title: "Release QA", persona: "Check each build.", backend: .herdr)
        let patch = Bot(name: "Patch", backend: .herdr)
        scout.canManageBots = true
        scout.sessionID = "private-session"
        source.bots = [patch, scout]
        source.setHerdrTemplate("swarmhub-codex", for: scout)
        source.setHerdrModel("example-model", for: scout)
        let group = try #require(source.createGroup(name: "Release crew", memberIDs: [scout.id, patch.id]))
        let data = try TeamPack(group: group, store: source).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("private-session"))
        #expect(!text.contains(scout.id.uuidString))
        let pack = try TeamPack.decode(data)
        let previousBotIDs = destination.bots.map(\.id), previousGroupIDs = destination.groups.map(\.id)
        // Another writer changes the revision after we have opened the destination.
        let old = try destination.currentStoreRevision()
        try Data("changed".utf8).write(to: destination.fileURL)
        #expect(throws: (any Error).self) { try destination.importTeamPack(pack, on: destination.herdrServers[0]) }
        #expect(destination.bots.map(\.id) == previousBotIDs && destination.groups.map(\.id) == previousGroupIDs)
        if let old { try old.write(to: destination.fileURL) } else { try FileManager.default.removeItem(at: destination.fileURL) }
        try destination.importTeamPack(pack, on: destination.herdrServers[0])
        let imported = try #require(destination.selectedGroup)
        let members = destination.members(of: imported)
        #expect(members.map(\.name) == ["Scout", "Patch"])
        #expect(imported.id != group.id && imported.messages.isEmpty)
        #expect(members[0].id != scout.id && !members[0].canManageBots && members[0].messages.isEmpty)
        #expect(members[0].avatarLook == scout.avatarLook && members[0].persona == scout.persona)
        #expect(destination.herdrTemplate(for: members[0]) == "swarmhub-codex")
        #expect(destination.herdrModel(for: members[0]) == "example-model")
        scout.persona = "api_key=example-test-value"
        #expect(throws: (any Error).self) { try TeamPack(group: group, store: source).encoded() }
        #expect(throws: (any Error).self) { try TeamPack.decode(Data("{}".utf8)) }
    }
}
