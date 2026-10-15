import SwiftUI
import UniformTypeIdentifiers

/// P38 B: Settings → Connected apps → ChatGPT: connect the user's ChatGPT account through the local Codex app-server and
/// show whether live voice works with the subscription. The voice window itself is P38 C; nothing here opens it.
struct ChatGPTConnectedAppSection: View {
    @ObservedObject var account: ChatGPTConnection
    /// Renders pass false: the pane never starts a Codex process on its own there.
    var checksOnAppear = true
    @AppStorage("codexVoiceExecutable") private var executable = ""
    @State private var choosingExecutable = false
    var body: some View {
        Section("ChatGPT") {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.title2).frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ChatGPT").font(.headline)
                    if account.isConnected {
                        Text([account.email, account.plan?.capitalized].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Label(account.canUseVoice ? "Voice available" : "Subscription voice unavailable", systemImage: account.canUseVoice ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption).foregroundStyle(account.canUseVoice ? Color.green : Color.secondary)
                    } else { Text("Connect your ChatGPT account and check subscription voice access.").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if account.isBusy {
                    ProgressView().controlSize(.small)
                    if account.state != .disconnecting { Button("Cancel") { account.cancelSignIn() } }
                } else if account.isConnected {
                    Button("Disconnect", role: .destructive) { account.disconnect() }
                } else { Button("Connect") { account.connect() }.accessibilityIdentifier("connectedApps.chatgpt.connect") }
            }
            if account.state == .signingIn {
                Text("Finish signing in with ChatGPT in your browser. This page updates when you return.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = account.errorMessage { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if account.isConnected && !account.canUseVoice {
                Text(account.voiceAccessMessage).font(.caption).foregroundStyle(.secondary)
                Button("Check voice access again") { account.refresh(force: true) }
            }
            Text("Uses your ChatGPT subscription through Codex on this Mac. API-key billing is not used. Disconnecting ends any active voice session.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Connection options") {
                TextField("Codex executable (automatic if empty)", text: $executable).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Choose executable…") { choosingExecutable = true }
                    Button("Check connection") { account.refresh() }.disabled(account.isBusy || account.isConnected)
                }
                Text("The ChatGPT desktop app or Codex CLI must be installed on this Mac. SwarmHub keeps this connection separate from your other Codex sign-ins.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(account.isBusy || account.isConnected)
        }
        .task { if checksOnAppear { account.refresh() } }
        .fileImporter(isPresented: $choosingExecutable, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { executable = url.path }
        }
    }
}
