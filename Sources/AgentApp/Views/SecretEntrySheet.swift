import SwiftUI

/// P06 gap: the secret-entry sheet. The user types a key here; it goes to a 0600 file under Application Support and the
/// bot receives only the file path. Nothing is kept in the store or shown again.
struct SecretEntrySheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let prompt: SecretRequestPrompt
    @State private var value = ""
    @State private var failure: String?
    @FocusState private var keyFocused: Bool

    private var acceptance: Bool {
        #if DEBUG
        store.uiAcceptance != nil
        #else
        false
        #endif
    }
    private var botName: String { store.bots.first { $0.id == prompt.botID }?.name ?? "The bot" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(botName) asks for a secret: \(prompt.request.name)").font(.headline)
            if !prompt.request.reason.isEmpty { Text(prompt.request.reason).font(.system(size: 13)).foregroundStyle(.secondary) }
            SecureField("Paste the key", text: $value).textFieldStyle(.roundedBorder).focused($keyFocused)
            if acceptance {
                Text(UIAcceptanceMode.banner).font(.headline)
                Text("Saved only in memory until you quit. No file, Keychain item or message is created.")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Stored in a file only your account can read (mode 0600). \(botName) receives the file path, never the value.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("This file stays on this Mac. A bot on another host needs separate key intake there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure { Text(failure).foregroundStyle(.red).font(.callout).accessibilityLabel("Could not save: \(failure)") }
            HStack {
                Button("Cancel") { store.secretRequest = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(acceptance ? "Save dummy key" : "Save and send the path") {
                    let sent = store.provideSecret(prompt, value: value)
                    value = ""
                    if sent { store.secretRequest = nil; dismiss() }
                    else { failure = store.errorMessage ?? "Could not store the secret. Try again." }
                }.keyboardShortcut(.defaultAction).disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 460).onAppear { if acceptance { keyFocused = true } }.onDisappear { value = "" }
    }
}
