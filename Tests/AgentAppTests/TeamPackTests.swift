import Foundation
import Testing
@testable import AgentApp

@MainActor struct TeamPackTests {
    private func store() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    @Test func workflowRoundTripUsesImportedPeersAndReachesEachGroupMember() async throws {
        let source = store()
        let author = Bot(name: "Patch", backend: .herdr), reviewer = Bot(name: "Scout", backend: .herdr)
        source.bots = [author, reviewer]
        let group = try #require(source.createGroup(name: "Release team", memberIDs: [author.id, reviewer.id]))
        let skill = TeamSkill(name: "Release notes", instructions: "Describe user-visible changes first.")
        group.workflows[author.id] = .init(skills: [skill], handoffs: [.init(recipient: reviewer.id, condition: "The draft is ready for review.")])
        let encoded = try TeamPack(group: group, store: source).encoded()
        let bytes = String(decoding: encoded, as: UTF8.self).lowercased()
        #expect(!bytes.contains(author.id.uuidString.lowercased()) && !bytes.contains(reviewer.id.uuidString.lowercased()))
        let url = temporaryStore()
        let destination = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        destination.bots = [Bot(name: reviewer.name, backend: .herdr)]
        try destination.importTeamPack(TeamPack.decode(encoded), on: destination.herdrServers[0])
        let backend = GroupBackend(name: "fixture")
        let reopened = AppStore(storeURL: url, autoStart: false, backendFactory: { _ in backend },
                                keyStore: InMemoryKeyStore(), defaults: destination.defaults)
        let imported = try #require(reopened.groups.first)
        let members = reopened.members(of: imported)
        let peer = members[1].id
        #expect(imported.workflows[members[0].id]?.handoffs.first?.recipient == peer)
        #expect(try TeamPack(group: imported, store: reopened).encoded() == encoded)
        #expect(reopened.send(text: "Make the release notes", to: imported))
        try await waitUntil { !reopened.anyTurnRunning }
        let turns = await backend.turns()
        #expect(turns.count == 2)
        let first = try #require(turns.first?.text)
        #expect(first.contains(skill.instructions) && first.contains(peer.uuidString.lowercased()))
        #expect(first.contains("The draft is ready for review.") && first.contains("Make the release notes"))
        #expect(turns.last?.text.contains(skill.instructions) == false)
        reopened.removeMember(peer, from: imported)
        #expect(imported.workflows[members[0].id]?.handoffs.isEmpty == true)
        #expect(imported.workflows[members[0].id]?.skills == [skill])
    }

    @Test func configuredHandoffDeliversOnceToTheImportedPeerAndReturnsItsAnswer() async throws {
        let source = store(), author = Bot(name: "Patch", backend: .herdr), peer = Bot(name: "Scout", backend: .herdr)
        source.bots = [author, peer]
        let group = try #require(source.createGroup(name: "Source", memberIDs: [author.id, peer.id]))
        group.workflows[author.id] = .init(handoffs: [.init(recipient: peer.id, condition: "The draft is ready.")])
        group.workflows[peer.id] = .init(skills: [.init(name: "Review", instructions: "Check all release numbers.")])
        let engine = GroupBackend(name: "Fixture")
        let dest = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in engine },
                            keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bystander = Bot(name: "Scout", backend: .herdr)
        dest.bots = [bystander]
        try dest.importTeamPack(TeamPack.decode(TeamPack(group: group, store: source).encoded()), on: dest.herdrServers[0])
        let imported = try #require(dest.selectedGroup), members = dest.members(of: imported)
        let sender = members[0], receiver = members[1]
        dest.defaults.set([sender, receiver].map { $0.id.uuidString.lowercased() }, forKey: "herdrTeamMembers.\(dest.herdrServer(for: receiver).id)")
        #expect(dest.bridgeCoordinates(receiver))
        let fence = "```swarmhub\n{\"op\":\"group_handoff\",\"recipient\":\"" + receiver.id.uuidString + "\",\"task\":\"Review release 15.\"}\n```"
        await engine.setGroupReply("Ready for review.\n" + fence)
        #expect(dest.send(text: "@Patch prepare the draft", to: imported))
        try await waitUntil { !dest.anyTurnRunning }
        let task = try #require(receiver.messages.first { $0.metadata[AppStore.groupHandoffSourceKey] != nil })
        #expect(task.content.contains("Check all release numbers.") && task.content.contains("Review release 15."))
        #expect(imported.messages.contains { $0.role == .system && $0.content.contains("handed a task to Scout") })
        #expect(sender.messages.contains { $0.metadata[HerdrBotRelay.Key.kind] == HerdrBotRelay.answer })
        #expect(bystander.messages.isEmpty)
        let trigger = try #require(imported.messages.first { $0.role == .user })
        let reply = try #require(imported.messages.first { $0.role == .assistant })
        dest.deliverGroupHandoff(in: imported, from: sender, trigger: trigger, reply: reply, configured: imported.workflows[sender.id]!.handoffs)
        dest.setHerdrTakesMessages(false, for: receiver)
        #expect(dest.send(text: "@Patch prepare another draft", to: imported))
        try await waitUntil { !dest.anyTurnRunning }
        #expect(receiver.messages.filter { $0.metadata[AppStore.groupHandoffSourceKey] != nil }.count == 1)
        #expect(imported.messages.last?.content.contains("could not be sent") == true)
    }

    @Test func packRejectsCredentialsAndUnknownHandoffRecipientsBeforeImport() throws {
        let source = store(), one = Bot(name: "Patch"), two = Bot(name: "Scout")
        source.bots = [one, two]
        let group = try #require(source.createGroup(name: "Crew", memberIDs: [one.id, two.id]))
        group.workflows[one.id] = .init(skills: [.init(name: "Check", instructions: "api_key=example-test-value")])
        #expect(throws: (any Error).self) { try TeamPack(group: group, store: source).encoded() }
        group.workflows[one.id] = .init(handoffs: [.init(recipient: two.id, condition: "api_key=example-test-value")])
        #expect(throws: (any Error).self) { try TeamPack(group: group, store: source).encoded() }
        group.workflows[one.id] = .init(handoffs: [.init(recipient: two.id, condition: "Ready")])
        let data = try TeamPack(group: group, store: source).encoded()
        var pack = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var members = try #require(pack["members"] as? [[String: Any]])
        for recipient in [-1, 0, 2] {
            members[0]["workflow"] = ["skills": [], "handoffs": [["recipient": recipient, "condition": "Ready"]]]
            pack["members"] = members
            #expect(throws: (any Error).self) { try TeamPack.decode(JSONSerialization.data(withJSONObject: pack)) }
        }
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
