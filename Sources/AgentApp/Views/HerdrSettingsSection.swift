import SwiftUI

/// Settings → Advanced → Servers and keys: the SwarmHub bridge beside Herdr Core. Its address, its access token
/// (Keychain account `herdr`), a Test, and the agent runtime new Herdr bots start from.
struct HerdrSettingsSection: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage(HerdrBackend.urlKey) private var address = HerdrBackend.defaultURL
    @AppStorage(HerdrBackend.templateKey) private var template = ""
    @State private var token = ""; @State private var result = ""; @State private var testing = false
    @State private var templates: [HerdrClient.Template] = []

    var body: some View {
        Section("Herdr workspace") {
            TextField("Address", text: $address)
            SecureField("Access token", text: $token).onChange(of: token) { _, value in
                store.keyStore.setKey(value.trimmingCharacters(in: .whitespacesAndNewlines), for: HerdrBackend.keyAccount)
            }
            HerdrTemplatePicker(title: "Agent runtime for new bots", automatic: "First available", selection: $template, templates: templates)
            HStack { Button("Test") { test() }.disabled(testing); if testing { ProgressView().controlSize(.small) }; Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("Herdr Core runs agent programs such as Claude Code or Codex on your server. The workspace answers on that server's own 127.0.0.1 only: forward its port to this Mac (ssh -L 8787:127.0.0.1:8787 your-server), then give a bot the Herdr backend in its Advanced settings.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { token = store.keyStore.key(for: HerdrBackend.keyAccount) }
    }

    private func test() {
        testing = true; result = ""
        Task {
            do {
                let client = try store.herdrClient()
                result = try await HerdrBackend(client: client, botName: "", botID: UUID(), template: nil).testConnection()
                templates = try await store.herdrTemplates()
            } catch { result = error.localizedDescription }
            testing = false
        }
    }
}

/// A bot's own agent runtime, in its editor's Advanced part. The change applies when the bot next starts an agent.
struct HerdrBotSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var template = ""; @State private var templates: [HerdrClient.Template] = []; @State private var problem = ""

    var body: some View {
        Section("Herdr agent") {
            HerdrTemplatePicker(title: "Agent runtime", automatic: "Same as new bots", selection: $template, templates: templates)
                .onChange(of: template) { _, value in store.setHerdrTemplate(value, for: bot) }
            Text(problem.isEmpty ? "The agent keeps running on the Herdr machine between messages. A new runtime applies the next time this bot starts one." : problem)
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            template = store.defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""
            do { templates = try await store.herdrTemplates() } catch { problem = error.localizedDescription }
        }
    }
}

/// The templates the bridge reported, plus the saved choice when it is not among them (not loaded yet, or removed).
struct HerdrTemplatePicker: View {
    let title: String; let automatic: String
    @Binding var selection: String
    let templates: [HerdrClient.Template]

    var body: some View {
        Picker(title, selection: $selection) {
            Text(automatic).tag("")
            ForEach(templates, id: \.name) { Text($0.label).tag($0.name) }
            if !selection.isEmpty, !templates.contains(where: { $0.name == selection }) { Text(selection).tag(selection) }
        }
    }
}
