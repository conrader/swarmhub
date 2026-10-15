import AppKit
import Foundation
import Testing
@testable import AgentApp

@MainActor struct ArtifactAccessTests {
    @Test func aSentDocumentIsSavedForItsBotAndReattachingKeepsOneCopy() async throws {
        let backend = TestBackend(transport: .nativeSessions, streamMode: .reply)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Reader", backend: .hermes); store.bots = [bot]; store.selectedBot = bot
        let file = ChatAttachment(id: UUID(), kind: .text, name: "notes.txt", mimeType: "text/plain", byteCount: 5, text: "notes")
        #expect(store.send(text: "Read this", attachments: [file]))
        try await waitUntil { store.isIdle }
        let saved = try store.artifactList(for: bot.id)
        #expect(saved.map(\.name) == ["notes.txt"] && saved[0].ownerBotIDs == [bot.id])
        #expect(bot.messages.first?.metadata["artifact.\(file.id.uuidString)"] == saved[0].id.uuidString)
        let again = try store.artifactAttachment(saved[0], for: bot.id)
        #expect(again.sourceArtifactID == saved[0].id && again.text == "notes")
        #expect(store.send(text: "Once more", attachments: [again]))
        try await waitUntil { store.isIdle }
        #expect(try store.artifactList(for: bot.id).count == 1, "reusing a saved document does not make a second, unrevocable copy")
        let decoded = try JSONDecoder().decode(ChatAttachment.self, from: JSONEncoder().encode(again))
        #expect(decoded.sourceArtifactID == saved[0].id)
    }

    @Test func revokedAccessKeepsAQueuedGroupMemberFromReceivingTheDocument() async throws {
        let ownerBackend = TestBackend(transport: .nativeSessions, streamMode: .approvalThenFinish)
        let recipientBackend = TestBackend(transport: .nativeSessions, streamMode: .reply)
        let owner = Bot(name: "Owner", backend: .hermes), recipient = Bot(name: "Recipient", backend: .hermes)
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { $0.id == owner.id ? ownerBackend : recipientBackend },
                             keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.bots = [owner, recipient]
        let artifact = try store.artifacts().save(Data("Controlled evidence".utf8), name: "Evidence", mimeType: "text/plain", owners: [owner.id])
        try store.shareArtifact(artifact, with: recipient.id)
        let attachment = try store.artifactAttachment(artifact, for: recipient.id)
        let group = GroupChat(name: "Team", memberIDs: [owner.id, recipient.id]); store.groups = [group]
        #expect(store.send(text: "Read this", attachments: [attachment], to: group))
        try await ownerBackend.calls.wait { $0.contains("send") }
        try store.revokeArtifact(artifact, from: recipient.id)
        #expect(throws: (any Error).self) { try store.artifactAttachment(artifact, for: recipient.id) }
        ownerBackend.finishRun()
        try await waitUntil { store.isIdle }
        #expect(await recipientBackend.recordedCalls().filter { $0 == "send" }.isEmpty)
        #expect(group.messages.contains { $0.role == .system && $0.content.hasPrefix("Recipient was skipped:") })
        #expect(String(data: try store.artifacts().read(artifact.id, botID: owner.id), encoding: .utf8) == "Controlled evidence")

        store.selectedGroup = nil; store.selectedBot = recipient
        #expect(!store.send(text: "Read this", attachments: [attachment]), "a 1:1 send is refused too")
        #expect(recipient.messages.isEmpty && store.errorMessage?.contains("access") == true)
    }

    @Test func groupContextLeavesOutADocumentTheMemberCannotRead() async throws {
        let owner = Bot(name: "Owner", backend: .hermes), other = Bot(name: "Other", backend: .hermes)
        let backends = [owner.id: GroupBackend(name: "Owner"), other.id: GroupBackend(name: "Other")]
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { backends[$0.id]! }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        store.bots = [owner, other]
        let group = GroupChat(name: "Team", memberIDs: [owner.id, other.id]); store.groups = [group]
        let artifact = try store.artifacts().save(Data("SECRET-LEDGER".utf8), name: "Ledger", mimeType: "text/plain", owners: [owner.id])
        #expect(store.send(text: "@Owner check this", attachments: [try store.artifactAttachment(artifact, for: owner.id)], to: group))
        try await waitUntil { store.isIdle }
        #expect(backends[owner.id]!.sent.all.first?.text.contains("SECRET-LEDGER") == true)
        #expect(store.send(text: "Everyone: thoughts?", to: group))
        try await waitUntil { store.isIdle }
        let otherContext = try #require(backends[other.id]!.sent.all.first?.text)
        #expect(otherContext.contains("@Owner check this") && !otherContext.contains("SECRET-LEDGER"))
    }

    @Test func theLastReaderStaysAndATamperedFileIsNotUsed() throws {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let bot = Bot(name: "Only"), archive = Bot(name: "Archive"); archive.archivedMembers = []; store.bots = [bot, archive]
        let artifacts = try store.artifacts()
        let artifact = try artifacts.save(Data("original".utf8), name: "Doc", mimeType: "text/plain", owners: [bot.id, bot.id])
        #expect(artifact.ownerBotIDs == [bot.id])
        #expect(throws: (any Error).self) { try store.revokeArtifact(artifact, from: bot.id) }
        #expect(throws: (any Error).self) { try store.shareArtifact(artifact, with: archive.id) }
        #expect(throws: (any Error).self) { try artifacts.save(Data(count: RuntimeArtifacts.byteLimit + 1), name: "Big", mimeType: "text/plain", owners: [bot.id]) }
        try Data("tampered".utf8).write(to: artifacts.fileURL(artifact.id))
        #expect(throws: (any Error).self) { try artifacts.read(artifact.id, botID: bot.id) }
    }
}

@MainActor @Test func p38ShotsRenderFromASyntheticStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppP38-\(UUID().uuidString)")
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "p38", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessP38Shots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessP38Shots.names.count, "only the P38 shots")
}
