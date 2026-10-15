import AppKit
import Combine
import SwiftUI

/// P38 C shots of `--render-setup` (`--only p38c` renders just these): Settings → Voice and the voice window, each
/// without a ChatGPT connection (not set up) and with a stand-in connection whose voice is enabled; a chat with the
/// header's voice button, and the composer's dictation line for a missing deAPI key. Throwaway in-memory store and key
/// store; the stand-in connection answers nothing, so no Codex process, microphone or network is touched.
@MainActor enum HeadlessP38CShots {
    static let names = ["p38c-settings-voice-not-set-up", "p38c-settings-voice-ready", "p38c-voice-window-not-set-up",
                        "p38c-voice-window-ready", "p38c-chat-voice-button", "p38c-composer-dictation-not-set-up"]

    /// A connected ChatGPT account with voice enabled, for pictures only.
    final class StandInAccount: VoiceAccount {
        let isConnected = true, canUseVoice = true, voiceAccessMessage = "Voice enabled"
        let plan: String? = "plus"
        var onVoiceNotification: ((String, JSONValue) -> Void)?
        var onDisconnect: (() -> Void)?
        func refresh(force: Bool) {}
        func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue { throw LiveVoiceError.unavailable }
    }

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.botInfo.autoLoad = false
        let settings = NSSize(width: 760, height: 560), window = NSSize(width: 520, height: 720)
        let none = CodexVoiceSession(account: { nil }), account = StandInAccount(), ready = CodexVoiceSession(account: account)

        write(names[0], await png(AnyView(Form { SettingsVoicePane(voice: none) }.formStyle(.grouped).frame(width: 760, height: 560).background(AppColor.panel)), store, settings))
        store.keyStore.setKey("synthetic-deapi", for: DeAPICredentials.account)
        write(names[1], await png(AnyView(Form { SettingsVoicePane(voice: ready) }.formStyle(.grouped).frame(width: 760, height: 560).background(AppColor.panel)), store, settings))
        store.keyStore.setKey("", for: DeAPICredentials.account)

        write(names[2], await png(AnyView(VoiceChatView(voice: none)), store, window))
        ready.prepareContext(name: "Jarvis", messages: [("user", "Plan tomorrow's backups"), ("assistant", "Patch tonight, verify at 07:00.")])
        write(names[3], await png(AnyView(VoiceChatView(voice: ready)), store, window))

        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "shared")
        jarvis.avatarName = .allCases[0]
        jarvis.messages = [ChatMessage(role: .user, content: "Can you plan tomorrow's backups?", createdAt: .now.addingTimeInterval(-300)),
                           ChatMessage(role: .assistant, content: "Patch tonight, verify at 07:00.", createdAt: .now.addingTimeInterval(-240), turnState: .finished)]
        store.bots = [jarvis]; store.selectedBot = jarvis
        let previous = VoiceAccounts.chatGPT
        VoiceAccounts.chatGPT = account
        write(names[4], await png(AnyView(ChatView(bot: jarvis).frame(width: 820, height: 420).background(AppColor.chat)), store, NSSize(width: 820, height: 420)))
        let dictation = VoiceDictation(key: { "" })
        dictation.start(context: "shot")
        write(names[5], await png(AnyView(ComposerView(text: .constant("Draft to"), attachments: .constant([]), isStreaming: false, send: {}, stop: {},
                                                       dictationContext: "shot", dictation: dictation)
            .frame(width: 820, height: 150).background(AppColor.chat)), store, NSSize(width: 820, height: 150)))
        VoiceAccounts.chatGPT = previous
    }
}
