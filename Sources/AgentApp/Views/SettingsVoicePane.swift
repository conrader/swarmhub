import SwiftUI

/// Settings → Advanced → Voice. The deAPI key for dictation (stored like other keys: the v2 Keychain item via
/// `store.keyStore`, existence read from attributes only).
struct SettingsVoicePane: View {
    static let deAPIKeysPage = URL(string: "https://app.deapi.ai")!
    @EnvironmentObject private var store: AppStore
    @State private var key = ""
    @State private var saved = false
    @State private var message = ""
    @State private var failed = false

    var body: some View {
        Section("Dictation") {
            Text(saved ? "Speak a message with the microphone button in any chat, then check the text and send it."
                 : "Speak your messages instead of typing them. Dictation uses deAPI, a transcription service: paste your deAPI key and a microphone button appears in every chat.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField(saved ? "Replace deAPI API key" : "deAPI API key", text: $key)
                .accessibilityLabel("deAPI API key").accessibilityIdentifier("voice.dictationKey")
            HStack {
                Button("Save key", action: saveKey).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saved { Button("Remove key", action: removeKey) }
                Spacer()
                Button("Get a deAPI key ↗") { ExternalLink.open(Self.deAPIKeysPage) }.buttonStyle(.link)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Color.secondary) }
            else if saved { Label("Key saved on this Mac", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
        }
        Section("Good to know") {
            Text("Recordings go to deAPI on your account and credits, last up to 5 minutes, and are deleted from this Mac afterwards. Switching chats or leaving the app cancels a recording; one already sent may still be charged.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { saved = store.keyStore.hasKey(for: DeAPICredentials.account) }
    }

    private func saveKey() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        failed = !store.keyStore.storeVerified(value, for: DeAPICredentials.account)
        if failed { message = "The key could not be saved. Unlock your Mac's keychain and try again." }
        else { key = ""; saved = true; message = "Saved. The microphone is now in every chat's message box."; store.dictationKeyChanged() }
    }
    private func removeKey() {
        store.keyStore.setKey("", for: DeAPICredentials.account)
        failed = store.keyStore.hasKey(for: DeAPICredentials.account)
        if failed { message = "The key could not be removed. Unlock your Mac's keychain and try again." }
        else { key = ""; saved = false; message = "Key removed."; store.dictationKeyChanged() }
    }
}
