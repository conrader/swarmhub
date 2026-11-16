import SwiftUI

/// Settings → Advanced → Servers and keys, under each Herdr server: that server's helper settings. A bot's agent
/// says how hard a helper's task is; here the person decides what each difficulty runs on, how many helpers one
/// agent may have at once, how long a helper stays after its answer, and how long one may go without answering. The server keeps the policy and checks it;
/// every agent program and model offered here is one the server listed, and Save sends the whole policy back.
struct HerdrHelperPolicySection: View {
    /// What a read of the server gave: its settings, its templates and each used template's models.
    struct Loaded: Equatable {
        var settings: HerdrHelperSettings; var templates: [HerdrClient.Template] = []; var models: [String: [HerdrClient.Template.Model]] = [:]
    }
    enum Phase: Equatable { case idle, reading, ready, unavailable(String) }

    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    /// With several servers the section says whose settings these are.
    let named: Bool
    @State private var phase: Phase; @State private var draft: HerdrHelperPolicyDraft; @State private var saved: HerdrHelperPolicyDraft
    @State private var templates: [HerdrClient.Template]; @State private var models: [String: [HerdrClient.Template.Model]]
    @State private var problem: String; @State private var note = ""; @State private var saving = false

    /// `preset` (renders and tests) shows a read without making one.
    init(server: HerdrServer, named: Bool = false, preset: Loaded? = nil) {
        self.server = server; self.named = named
        let start = preset.map { HerdrHelperPolicyDraft($0.settings) } ?? HerdrHelperPolicyDraft()
        _phase = State(initialValue: preset == nil ? .idle : .ready); _draft = State(initialValue: start); _saved = State(initialValue: start)
        _templates = State(initialValue: HerdrHelperPolicyDraft.templates(in: preset?.templates ?? [])); _models = State(initialValue: preset?.models ?? [:])
        _problem = State(initialValue: preset?.settings.problem ?? "")
    }

    var body: some View {
        Section(named ? "Helper agents on \(server.name)" : "Helper agents") {
            switch phase {
            case .idle: Button("Read this server's helper settings") { Task { await load() } }
            case .reading: HStack { ProgressView().controlSize(.small); Text("Reading this server's helper settings…").foregroundStyle(.secondary) }
            case .unavailable(let why):
                Text(why).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Read again") { Task { await load() } }
            case .ready: form
            }
            Text("A bot hands parts of its work to helpers, unless its “Can start helper agents” is off, and says how hard each part is. It cannot choose a model: these settings do, for every bot on \(server.name).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if phase == .idle, store.launchWorkEnabled { await load() } }
    }

    @ViewBuilder private var form: some View {
        ForEach(HerdrHelperNote.difficulties, id: \.self) { difficulty in
            let tier = draft.tiers[difficulty]
            Picker("\(difficulty.capitalized) tasks run on", selection: Binding(get: { tier?.template ?? "" }, set: { choose($0, for: difficulty) })) {
                Text("Not allowed").tag("")
                ForEach(templates, id: \.name) { Text($0.label).tag($0.name) }
                if let chosen = tier?.template, !chosen.isEmpty, !templates.contains(where: { $0.name == chosen }) { Text(chosen).tag(chosen) }
            }
            if let tier, !tier.template.isEmpty {
                let offered = models[tier.template] ?? []
                Picker("Model for \(difficulty) tasks", selection: Binding(get: { tier.model }, set: { draft.tiers[difficulty]?.model = $0; note = "" })) {
                    if tier.model.isEmpty { Text(offered.isEmpty ? "Reading…" : "Choose…").tag("") }
                    ForEach(offered, id: \.id) { Text($0.label ?? $0.id).tag($0.id) }
                    if !tier.model.isEmpty, !offered.contains(where: { $0.id == tier.model }) { Text(tier.model).tag(tier.model) }
                }
            }
        }
        Stepper("Helpers one agent may have at once: \(draft.maxRunning)", value: $draft.maxRunning, in: draft.runningRange)
        Picker("A helper disappears after its answer in", selection: $draft.stopAfterSeconds) {
            ForEach(draft.delays(), id: \.self) { Text(HerdrHelperPolicyDraft.delayLabel($0)).tag($0) }
        }
        // Only a server that has this setting: an older workspace does not, and is not sent it.
        if let unanswered = draft.stopUnansweredSeconds {
            Picker("A helper that has not answered is stopped after", selection: Binding(get: { unanswered }, set: { draft.stopUnansweredSeconds = $0 })) {
                ForEach(draft.unansweredDelays(), id: \.self) { Text(HerdrHelperPolicyDraft.delayLabel($0)).tag($0) }
            }
            .help("Counts from when the helper got its task, whether it waits at a prompt or is still working. Choose longer for long jobs.")
        }
        HStack {
            Button("Save") { save() }.disabled(saving || draft == saved || draft.problem != nil)
            if draft != saved { Button("Revert") { draft = saved; note = "" }.disabled(saving) }
            if saving { ProgressView().controlSize(.small) }
            Text(draft.problem ?? note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        if !problem.isEmpty {
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Picks the agent program for a difficulty; its model becomes the first one the server lists for it, read now when
    /// it was not read before.
    private func choose(_ template: String, for difficulty: String) {
        note = ""
        draft.setTemplate(template, for: difficulty, offered: models[template] ?? [])
        guard !template.isEmpty, models[template] == nil else { return }
        Task {
            await loadModels(for: [template])
            if draft.tiers[difficulty]?.template == template, draft.tiers[difficulty]?.model.isEmpty == true { draft.setTemplate(template, for: difficulty, offered: models[template] ?? []) }
        }
    }

    private func load() async {
        phase = .reading; note = ""
        do {
            let client = try store.herdrClient(for: server)
            let settings = try await client.helperSettings()
            templates = HerdrHelperPolicyDraft.templates(in: try await client.workspace().templates)
            show(settings)
            phase = .ready
            await loadModels(for: Set(draft.tiers.values.map(\.template)))
        } catch { phase = .unavailable(Self.reason(error)) }
    }

    private func show(_ settings: HerdrHelperSettings) {
        draft = HerdrHelperPolicyDraft(settings); saved = draft; problem = settings.problem ?? ""
    }

    private func loadModels(for names: Set<String>) async {
        guard let client = try? store.herdrClient(for: server) else { return }
        for template in templates where names.contains(template.name) && models[template.name] == nil {
            models[template.name] = (try? await client.models(for: template)) ?? template.models ?? []
        }
    }

    private func save() {
        guard draft.problem == nil, !saving else { return }
        let sending = draft.policy
        saving = true; note = ""
        Task {
            do {
                show(try await store.herdrClient(for: server).saveHelperPolicy(sending))
                note = "Saved on \(server.name). It applies to the next helper an agent starts."
            } catch { note = Self.reason(error) }
            saving = false
        }
    }

    /// A server whose Herdr workspace is older has no such settings; everything else speaks for itself.
    nonisolated static func reason(_ error: Error) -> String {
        if case .http(404, _)? = error as? HerdrClient.Failure { return "This server's Herdr workspace is older and has no helper settings. Update swarmhub-herdr on the server, then read again." }
        return error.localizedDescription
    }
}
