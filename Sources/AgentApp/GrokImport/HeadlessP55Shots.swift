import AppKit
import Combine
import SwiftUI

/// P55 shots of `--render-setup` (alone with `--only p55`): the voice window after a start that failed at the
/// microphone (access off, with the button to its settings pane) and after ChatGPT refused live voice (its JSON-RPC
/// code and redacted message). Each session really runs its steps against stand-ins: the account answers from memory
/// and the audio device never opens a microphone; no Codex process, network or Keychain is touched.
@MainActor enum HeadlessP55Shots {
    static let names = ["p55-voice-microphone-off", "p55-voice-chatgpt-refused"]

    /// A connected account with voice enabled whose `thread/realtime/start` is refused like a workspace without voice.
    final class RefusingAccount: VoiceAccount {
        let isConnected = true, canUseVoice = true, voiceAccessMessage = "Voice enabled"
        let plan: String? = "plus"
        var onVoiceNotification: ((String, JSONValue) -> Void)?
        var onDisconnect: (() -> Void)?
        func refresh(force: Bool) {}
        func request(_ method: String, params: [String: JSONValue], timeout: Duration) async throws -> JSONValue {
            switch method {
            case "thread/start": return .object(["thread": .object(["id": .string("p55-render")])])
            case "thread/realtime/start":
                throw CodexRPCError(code: -32000, message: "Realtime voice is not enabled for this workspace. Authorization: Bearer synthetic-render-token")
            default: return .object([:])
            }
        }
    }

    /// Permission is refused (or granted) without asking macOS; `start` never runs in these shots.
    final class StandInAudio: CodexVoiceAudioDevice {
        let denies: Bool
        init(denies: Bool) { self.denies = denies }
        func requestPermission() async throws { if denies { throw VoiceDictationError.permissionDenied } }
        func start() throws -> AsyncThrowingStream<CodexVoiceAudioChunk, Error> { throw LiveVoiceError.audioUnavailable }
        func play(_ chunk: CodexVoiceAudioChunk) throws {}
        func interruptPlayback() {}
        func stop() {}
    }

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false; store.botInfo.autoLoad = false
        let window = NSSize(width: 520, height: 760)
        for (name, denies) in zip(names, [true, false]) {
            let voice = CodexVoiceSession(account: RefusingAccount(), makeAudio: { StandInAudio(denies: denies) })
            voice.prepareContext(name: "Jarvis", messages: [("user", "Plan tomorrow's backups")])
            voice.start()
            for _ in 0..<200 where voice.failure == nil || voice.state != .idle { try? await Task.sleep(for: .milliseconds(10)) }
            write(name, voice.failure == nil ? nil : await png(AnyView(VoiceChatView(voice: voice)), store, window))
        }
    }
}
