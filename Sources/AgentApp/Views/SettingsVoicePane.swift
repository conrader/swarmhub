import SwiftUI

/// P38 C: Settings → Advanced → Voice. The deAPI key for dictation (stored like other keys: the v2 Keychain item via
/// `store.keyStore`, existence read from attributes only) and live voice's state with the ChatGPT connection.
struct SettingsVoicePane: View {
    static let deAPIKeysPage = URL(string: "https://app.deapi.ai")!
    @EnvironmentObject private var store: AppStore
    @ObservedObject var voice: CodexVoiceSession = .shared
    @Environment(\.openWindow) private var openWindow
    @State private var key = ""
    @State private var saved = false
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        Section("Voice dictation · deAPI") {
            Text("Record a message with the microphone button in any chat. Stop recording to transcribe it, then review the draft and send when ready.")
                .font(.callout).foregroundStyle(.secondary)
            if !saved {
                Text("Not set up: dictation needs a deAPI API key.").font(.caption).foregroundStyle(.secondary)
            }
            SecureField(saved ? "Replace deAPI API key" : "deAPI API key", text: $key)
                .accessibilityLabel("deAPI API key").accessibilityIdentifier("voice.dictationKey")
            HStack {
                Button("Save key", action: saveKey).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved { Button("Remove key", action: removeKey) }
                Spacer()
                Button("Get a deAPI key ↗") { ExternalLink.open(Self.deAPIKeysPage) }.buttonStyle(.link)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary) }
            else if saved { Label("API key saved in Keychain", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
        }
        Section("Recording and transcription") {
            Text("Stopped recordings are sent to deAPI using your account and credits. Language is detected automatically. Recordings are limited to 5 minutes and removed from this Mac after transcription or cancellation.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Switching chats or closing the chat cancels dictation. Leaving the app while recording discards the recording. Cancelling after an upload stops waiting for the result; deAPI may still finish and charge for that job.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Live voice with ChatGPT") {
            if let account = voice.account {
                Label(voice.canUseVoice ? "Voice enabled" : voice.accessMessage, systemImage: voice.canUseVoice ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout).foregroundStyle(voice.canUseVoice ? Color.green : Color.secondary)
                    .accessibilityIdentifier("voice.live")
                HStack {
                    if voice.canUseVoice { Button("Open voice window") { openWindow(id: VoiceChatView.windowID) } }
                    else if account.isConnected { Button("Check voice access again") { account.refresh(force: true) } }
                }
            } else {
                Text(VoiceAccounts.notSetUp).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("voice.live")
            }
            Text("Live voice talks with ChatGPT through your ChatGPT subscription (the local ChatGPT app or Codex CLI). It is separate from your agents: it can read a snapshot of the chat you open it from, and sends nothing to them until you review and send an instruction.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { saved = store.keyStore.hasKey(for: DeAPICredentials.account) }
    }

    private func saveKey() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        failed = !store.keyStore.storeVerified(value, for: DeAPICredentials.account)
        if failed { message = "Could not save the key to macOS Keychain. Please try again." }
        else { key = ""; saved = true; message = "API key saved in macOS Keychain." }
    }
    private func removeKey() {
        store.keyStore.setKey("", for: DeAPICredentials.account)
        failed = store.keyStore.hasKey(for: DeAPICredentials.account)
        if failed { message = "Could not remove the key from macOS Keychain. Please try again." }
        else { key = ""; saved = false; message = "API key removed." }
    }
}
