import Foundation
import Testing
@testable import AgentApp

/// P38 C: saved voice conversations on disk, the reviewed handoff into the chat voice was opened from, the deAPI key
/// in the injected key store, and the Voice pane's place in Settings.
@MainActor struct VoiceHandoffTests {
    private func saved(_ target: ConversationActionTarget?, name: String = "Planning") -> SavedVoiceConversation {
        SavedVoiceConversation(id: UUID(), name: name, target: target, contextRevision: "rev",
                               entries: [.init(id: "1", role: "user", text: "Plan tomorrow"), .init(id: "2", role: "assistant", text: "Start with the backups.")],
                               summary: "Check the backups first")
    }

    @Test func savedVoiceConversationsRoundTripNewestFirstNextToTheStore() throws {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(try store.savedVoice().isEmpty)
        var older = saved(nil, name: "Older"); older.createdAt = .now.addingTimeInterval(-60)
        let newer = saved(.bot(botID: UUID(), threadID: nil), name: "Newer")
        try store.saveVoice(older); try store.saveVoice(newer)
        older.summary = "Edited"; try store.saveVoice(older)
        let records = try store.savedVoice()
        #expect(records.map(\.name) == ["Newer", "Older"] && records[1].summary == "Edited" && records[0] == newer)
        #expect(store.voiceArchive.fileURL.deletingLastPathComponent().deletingLastPathComponent() == store.fileURL.deletingLastPathComponent())
        #expect(newer.exportText.contains("You: Plan tomorrow") && newer.exportText.contains("ChatGPT: Start with the backups."))
    }

    @Test func handoffGoesOnceToTheChatVoiceWasOpenedFrom() async throws {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let owner = Bot(name: "Owner"), other = Bot(name: "Other")
        store.bots = [owner, other]; store.selectedBot = other
        let value = saved(.bot(botID: owner.id, threadID: nil))
        #expect(!store.handoffVoice(value, text: "Do it", target: .bot(botID: other.id, threadID: nil)), "never to another chat")
        #expect(!store.handoffVoice(value, text: "  ", target: value.target!))
        #expect(store.handoffVoice(value, text: "Check the backups first", target: value.target!))
        try await waitUntil { store.isIdle }
        let sent = try #require(owner.messages.first { $0.role == .user })
        #expect(sent.content.hasPrefix("Reviewed voice handoff from Planning") && sent.content.hasSuffix("Check the backups first"))
        #expect(sent.metadata[AppStore.voiceSourceKey] == value.id.uuidString && other.messages.isEmpty)
        #expect(!store.handoffVoice(value, text: "Again", target: value.target!), "a saved conversation is handed off once")
        #expect(store.errorMessage?.contains("already been added") == true)
    }

    @Test func groupHandoffGoesToThePickedMemberOfTheSameGroup() async throws {
        let backend = GroupBackend(name: "B")
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend }, keyStore: InMemoryKeyStore(), defaults: namedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B")
        store.bots = [a, b]
        let group = GroupChat(name: "Team", memberIDs: [a.id, b.id], messages: []), elsewhere = GroupChat(name: "Else", memberIDs: [a.id, b.id], messages: [])
        store.groups = [group, elsewhere]
        let value = saved(.group(groupID: group.id, botID: a.id))
        #expect(!store.handoffVoice(value, text: "Go", target: .group(groupID: elsewhere.id, botID: b.id)))
        #expect(store.handoffVoice(value, text: "Go", target: .group(groupID: group.id, botID: b.id)))
        try await waitUntil { store.isIdle }
        #expect(backend.sent.all.count == 1 && backend.sent.all.first?.session.contains(b.id.uuidString.lowercased()) == true)
        #expect(group.messages.first { $0.role == .user }?.metadata[AppStore.voiceSourceKey] == value.id.uuidString && elsewhere.messages.isEmpty)
    }

    @Test func handoffToAGoneConversationIsRefused() {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let value = saved(.bot(botID: UUID(), threadID: nil))
        #expect(!store.handoffVoice(value, text: "Go", target: value.target!))
        #expect(store.errorMessage == "The original voice destination is unavailable.")
        #expect(!store.handoffVoice(saved(nil), text: "Go", target: .bot(botID: UUID(), threadID: nil)))
    }

    @Test func dictationKeyLivesInTheKeyStoreUnderTheOldAccount() {
        let keys = InMemoryKeyStore()
        #expect(DeAPICredentials.account == "deapi.dictation")
        #expect(!keys.hasKey(for: DeAPICredentials.account))
        #expect(keys.storeVerified("synthetic-deapi", for: DeAPICredentials.account) && keys.hasKey(for: DeAPICredentials.account))
        keys.setKey("", for: DeAPICredentials.account)
        #expect(!keys.hasKey(for: DeAPICredentials.account))
        #expect(DeAPIError.missingKey.localizedDescription.contains(SettingsLayout.path(.voice)))
    }

    @Test func voicePaneHoldsTheDictationKeyAndLiveVoice() {
        #expect(SettingsLayout.ids(in: .voice) == ["voice.dictationKey", "voice.live"])
        #expect(SettingsLayout.AdvancedPane.allCases.contains(.voice) && SettingsLayout.AdvancedPane.voice.icon == "mic")
    }
}
