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
        VStack(alignment: .leading, spacing: 22) {
            GroupHeading(title: named ? "Helpers on \(server.name)" : "Helpers",
                         detail: "Bots can hand parts of their work to helpers and say how hard each part is. Choose what runs each kind of task.")
            switch phase {
            case .idle: Button("Show helper settings") { Task { await load() } }
            case .reading: StatusCard(kind: .working, title: "Checking…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The helper settings could not be loaded", detail: why) { Button("Try again") { Task { await load() } }.padding(.top, 4) }
            case .ready: form
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked.
        .task(id: server.id) { if phase == .idle, store.launchWorkEnabled { await load() } }
    }

    /// Each difficulty is a heading with two galleries (the agent program, then its model); then how many helpers,
    /// and the two waits as galleries of round times. Save sends the whole policy.
    @ViewBuilder private var form: some View {
        ForEach(HerdrHelperNote.difficulties, id: \.self) { difficulty in
            let tier = draft.tiers[difficulty]
            SettingBlock(title: "\(difficulty.capitalized) tasks", detail: "") {
                let unlisted = tier.flatMap { chosen in !chosen.template.isEmpty && !templates.contains(where: { $0.name == chosen.template }) ? [NamedChoice(id: chosen.template, name: chosen.template)] : nil } ?? []
                let programs = [NamedChoice(id: "", name: "Not allowed")] + templates.map { NamedChoice(id: $0.name, name: HerdrProgramName.labels(for: templates)[$0.name] ?? $0.label) } + unlisted
                TileGallery(items: programs, minimum: 150, isSelected: { $0.id == (tier?.template ?? "") }, name: { "\(difficulty.capitalized) tasks run on \($0.name)" }, select: { choose($0.id, for: difficulty) }) { choice in
                    NameTile(name: choice.name, symbol: choice.id.isEmpty ? "nosign" : nil)
                }
                if let tier, !tier.template.isEmpty {
                    let offered = models[tier.template] ?? []
                    let extra = !tier.model.isEmpty && !offered.contains(where: { $0.id == tier.model }) ? [NamedChoice(id: tier.model, name: tier.model)] : []
                    let choices = offered.map { NamedChoice(id: $0.id, name: $0.label ?? $0.id) } + extra
                    if choices.isEmpty { Text("Checking its models…").font(.callout).foregroundStyle(.secondary) }
                    else {
                        Text(tier.model.isEmpty ? "Choose a model" : "Model").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.top, 4)
                        TileGallery(items: choices, minimum: 150, isSelected: { $0.id == tier.model }, name: { "Model for \(difficulty) tasks: \($0.name)" }, select: { draft.tiers[difficulty]?.model = $0.id; note = "" }) { NameTile(name: $0.name) }
                    }
                }
            }
        }
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Helpers at once").font(.headline)
                Text("How many helpers one bot may run at the same time.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Stepper(value: $draft.maxRunning, in: draft.runningRange) { Text("\(draft.maxRunning)").font(.title3.weight(.semibold)).monospacedDigit().frame(minWidth: 24, alignment: .trailing) }
                .accessibilityLabel("Helpers one bot may run at once").accessibilityValue("\(draft.maxRunning)")
        }
        SettingBlock(title: "After its answer", detail: "A helper leaves this long after it has answered.") {
            TileGallery(items: draft.delays().map { NamedChoice(id: String($0), name: HerdrHelperPolicyDraft.delayLabel($0)) }, minimum: 96, isSelected: { $0.id == String(draft.stopAfterSeconds) }, name: \.name,
                        select: { if let seconds = Int($0.id) { draft.stopAfterSeconds = seconds } }) { NameTile(name: $0.name) }
        }
        // Only a server that has this setting: an older workspace does not, and is not sent it.
        if let unanswered = draft.stopUnansweredSeconds {
            SettingBlock(title: "Without an answer", detail: "A helper that has not answered is stopped after this long. Choose longer for long jobs.") {
                TileGallery(items: draft.unansweredDelays().map { NamedChoice(id: String($0), name: HerdrHelperPolicyDraft.delayLabel($0)) }, minimum: 96, isSelected: { $0.id == String(unanswered) }, name: \.name,
                            select: { if let seconds = Int($0.id) { draft.stopUnansweredSeconds = seconds } }) { NameTile(name: $0.name) }
            }
        }
        if !problem.isEmpty { StatusCard(kind: .warning, title: problem) }
        HStack(spacing: 10) {
            Button("Save") { save() }.buttonStyle(.appleProminent).disabled(saving || draft == saved || draft.problem != nil)
            if draft != saved { Button("Revert") { draft = saved; note = "" }.disabled(saving) }
            if saving { ProgressView().controlSize(.small) }
            Text(draft.problem ?? note).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.controlSize(.large)
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
                note = "Saved. It applies to the next helper a bot starts."
            } catch { note = Self.reason(error) }
            saving = false
        }
    }

    /// A server whose Herdr workspace is older has no such settings; everything else speaks for itself.
    nonisolated static func reason(_ error: Error) -> String {
        if case .http(404, _)? = error as? HerdrClient.Failure { return "This server needs an update before helpers can be set up here. Update the \(AppConstants.name) service on it (swarmhub-herdr), then try again." }
        return error.localizedDescription
    }
}
