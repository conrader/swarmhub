import AppKit
import Foundation
import Testing
@testable import AgentApp

@MainActor struct ArtifactAccessTests {
    @Test func aSentDocumentIsSavedForItsBotAndReattachingKeepsOneCopy() async throws {
        let backend = TestBackend(streamMode: .reply)
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Reader", backend: .herdr); store.bots = [bot]; store.selectedBot = bot
        let file = ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 5, text: "notes")
        #expect(store.send(text: "Read this", attachments: [file]))
        try await waitUntil { !store.anyTurnRunning }
        let saved = try store.artifactList(for: bot.id)
        #expect(saved.map(\.name) == (["notes.txt"] as [String]) && saved[0].ownerBotIDs == ([bot.id] as [UUID]))
        #expect(bot.messages.first?.metadata["artifact.\(file.id.uuidString)"] == saved[0].id.uuidString)
        let again = try store.artifactAttachment(saved[0], for: bot.id)
        #expect(again.sourceArtifactID == saved[0].id && again.text == "notes")
        #expect(store.send(text: "Once more", attachments: [again]))
        try await waitUntil { !store.anyTurnRunning }
        #expect(try store.artifactList(for: bot.id).count == 1, "reusing a saved document does not make a second, unrevocable copy")
        let decoded = try JSONDecoder().decode(ChatAttachment.self, from: JSONEncoder().encode(again))
        #expect(decoded.sourceArtifactID == saved[0].id)
    }

    @Test func groupContextLeavesOutADocumentTheMemberCannotRead() async throws {
        let owner = Bot(name: "Owner", backend: .herdr), other = Bot(name: "Other", backend: .herdr)
        let backends = [owner.id: GroupBackend(name: "Owner"), other.id: GroupBackend(name: "Other")]
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { backends[$0.id]! }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.bots = [owner, other]
        let group = GroupChat(name: "Team", memberIDs: [owner.id, other.id]); store.groups = [group]
        let artifact = try store.artifacts().save(Data("SECRET-LEDGER".utf8), name: "Ledger", mimeType: "text/plain", owners: [owner.id])
        #expect(store.send(text: "@Owner check this", attachments: [try store.artifactAttachment(artifact, for: owner.id)], to: group))
        try await waitUntil { !store.anyTurnRunning }
        #expect(backends[owner.id]!.sent.all.first?.text.contains("SECRET-LEDGER") == true)
        #expect(store.send(text: "Everyone: thoughts?", to: group))
        try await waitUntil { !store.anyTurnRunning }
        let otherContext = try #require(backends[other.id]!.sent.all.first?.text)
        #expect(otherContext.contains("@Owner check this") && !otherContext.contains("SECRET-LEDGER"))
    }

    @Test func theLastReaderStaysAndATamperedFileIsNotUsed() throws {
        let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Only"), archive = Bot(name: "Archive"); archive.archivedMembers = []; store.bots = [bot, archive]
        let artifacts = try store.artifacts()
        let artifact = try artifacts.save(Data("original".utf8), name: "Doc", mimeType: "text/plain", owners: [bot.id, bot.id])
        #expect(artifact.ownerBotIDs == ([bot.id] as [UUID]))
        #expect(throws: (any Error).self) { try store.revokeArtifact(artifact, from: bot.id) }
        #expect(throws: (any Error).self) { try store.shareArtifact(artifact, with: archive.id) }
        #expect(throws: (any Error).self) { try artifacts.save(Data(count: RuntimeArtifacts.byteLimit + 1), name: "Big", mimeType: "text/plain", owners: [bot.id]) }
        try Data("tampered".utf8).write(to: artifacts.fileURL(artifact.id))
        #expect(throws: (any Error).self) { try artifacts.read(artifact.id, botID: bot.id) }
    }
}

