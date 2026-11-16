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
            HStack {
                Button("Test") { test() }.disabled(testing)
                Button("Add starter bots") { addStarters() }.disabled(testing).help("Adds one bot for each agent program your Herdr server has, on the model the server lists first.")
                if testing { ProgressView().controlSize(.small) }
                Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Herdr Core runs agent programs such as Claude Code or Codex on your server. The workspace answers on that server's own 127.0.0.1 only: forward its port to this Mac (ssh -L 8787:127.0.0.1:8787 your-server), then give a bot the Herdr backend in its Advanced settings.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { token = store.keyStore.key(for: HerdrBackend.keyAccount) }
    }

    private func addStarters() {
        testing = true; result = ""
        Task {
            do {
                let added = try await store.addHerdrStarterBots()
                result = added.isEmpty ? "Your Herdr agent programs already have a bot each." : "Added \(added.joined(separator: " and ")). Find them in the sidebar."
            } catch { result = error.localizedDescription }
            testing = false
        }
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

/// A Herdr bot's agent in its editor's Advanced part: the same controls as the Details panel's Model tab.
struct HerdrBotSection: View {
    @ObservedObject var bot: Bot
    var body: some View { Section("Herdr agent") { HerdrAgentControls(bot: bot) } }
}

/// Which agent program and model a Herdr bot runs, and a way to start it afresh. Both choices are used when the bot
/// next starts an agent; a running agent keeps what it started with until "Start a fresh agent".
struct HerdrAgentControls: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var template = ""; @State private var model = ""
    @State private var templates: [HerdrClient.Template] = []; @State private var models: [HerdrClient.Template.Model] = []
    @State private var note = ""; @State private var loaded = false; @State private var restarting = false; @State private var steers = true

    /// The template this bot would start from now: its own, else the one for new bots, else the first available.
    private var effective: HerdrClient.Template? {
        let wanted = template.isEmpty ? store.defaults.string(forKey: HerdrBackend.templateKey) ?? "" : template
        return templates.first { $0.name == wanted } ?? (wanted.isEmpty ? templates.first : nil)
    }

    var body: some View {
        HerdrTemplatePicker(title: "Agent runtime", automatic: "Same as new bots", selection: $template, templates: templates)
            .onChange(of: template) { _, value in
                guard loaded else { return }
                store.setHerdrTemplate(value, for: bot); model = ""; store.setHerdrModel("", for: bot)
                Task { await loadModels() }
            }
        if effective?.takesModel != false {
            Picker("Model", selection: $model) {
                Text("Agent's default").tag("")
                ForEach(models, id: \.id) { Text($0.label ?? $0.id).tag($0.id) }
                if !model.isEmpty, !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            }
            .onChange(of: model) { _, value in if loaded { store.setHerdrModel(value, for: bot) } }
        }
        Toggle("Add messages to the running answer (steer)", isOn: Binding(get: { steers }, set: { steers = $0; store.setHerdrSteers($0, for: bot) }))
            .help("On: a message you send while the agent is answering goes straight to it. Off: the message waits until the answer ends.")
        HStack {
            Button("Start a fresh agent") { restart() }.disabled(restarting)
            if restarting { ProgressView().controlSize(.small) }
        }
        Text(note.isEmpty ? "Runtime and model apply when this bot next starts an agent. A running agent keeps its own until you start a fresh one, which also clears what the agent remembers of this chat." : note)
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .task {
                template = store.defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""; model = store.herdrModel(for: bot); steers = store.herdrSteers(bot)
                do { templates = try await store.herdrTemplates() } catch { note = error.localizedDescription }
                await loadModels(); loaded = true
            }
    }

    private func loadModels() async {
        guard let effective, effective.takesModel else { models = []; return }
        do { models = try await store.herdrClient().models(for: effective) } catch { models = effective.models ?? [] }
    }

    private func restart() {
        restarting = true; note = ""
        Task {
            do { note = try await store.restartHerdrAgent(for: bot) ? "The running agent was closed. Your next message starts a fresh one." : "No agent is running. Your next message starts one." }
            catch { note = error.localizedDescription }
            restarting = false
        }
    }
}

/// Overview's line for a Herdr bot, where a Hermes bot shows its memory.
struct HerdrOverviewSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent").font(.headline)
            Text("Runs on your Herdr server as \((try? store.herdrBackend(for: bot).agentName) ?? "an agent named after this bot"). It keeps its own memory of the chat while it runs; choose its runtime and model under Model.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
