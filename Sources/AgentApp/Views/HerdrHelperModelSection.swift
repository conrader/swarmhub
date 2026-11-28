import SwiftUI

struct HerdrHelperModelSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let server: HerdrServer
    let templates: [HerdrClient.Template]
    var approvalsOnly = false
    var preset: HerdrClient.BotAgentSettings? = nil

    @State private var saved: HerdrClient.BotAgentSettings?
    @State private var program = ""
    @State private var model = ""
    @State private var approvalTemplates: [HerdrClient.Template] = []
    @State private var editingControls = false
    @State private var saving = false
    @State private var reviewerError: String?
    @State private var autoProblem = ""
    @State private var problem = ""

    private var programs: [HerdrClient.Template] { HerdrHelperPolicyDraft.templates(in: templates) }
    private var draft: HerdrHelperPolicy.Tier? { program.isEmpty ? nil : .init(template: program, model: model) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if approvalsOnly {
                HStack {
                    Text("Control level").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if saved != nil {
                        Button(editingControls ? "Done" : "Edit") { editingControls.toggle() }
                            .buttonStyle(.link).accessibilityLabel(editingControls ? "Finish editing approval controls" : "Edit approval controls")
                    }
                }
                if let saved {
                    LibraryFlow(spacing: 5) {
                        InspectorTag(text: saved.reviewEveryTool == true ? "New sessions: Ask every tool" : saved.autoMode ? "New sessions: Auto" : "New sessions: Standard")
                        if saved.commandReviewer != nil {
                            InspectorTag(text: "Command reviewer: " + saved.reviewerLabel)
                        }
                    }
                    if editingControls {
                        approvalSettings
                    } else if store.autoSwitchPending(bot) || store.herdrAgentReadings[bot.id]?.autoRestartPending == true {
                        Label("Change pending until the session is idle", systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if problem.isEmpty { ProgressView("Loading approval settings…").controlSize(.small) }
                else {
                    Text(problem).font(.callout)
                    Button("Try again") { Task { await load() } }
                }
            } else {
                helperModel
                approvalSettings
            }
        }.task(id: "\(bot.id)-\(server.id)") { await load() }
    }

    private var helperModel: some View {
        SettingBlock(title: "Helper model", detail: "For new helpers started by \(bot.name).") {
            if let saved {
                Picker("AI", selection: Binding(get: { program }, set: { program = $0; model = ""; problem = "" })) {
                    Text("Server settings by difficulty").tag("")
                    if !program.isEmpty && !programs.contains(where: { $0.name == program }) { Text(program).tag(program) }
                    ForEach(programs, id: \.name) { item in
                        Text(HerdrProgramName.labels(for: programs)[item.name] ?? item.label).tag(item.name)
                    }
                }.accessibilityLabel("Helper AI").tint(Color(nsColor: .secondaryLabelColor)).disabled(saving)
                if let template = programs.first(where: { $0.name == program }) {
                    HelperModelPicker(server: server, template: template, model: $model, preset: preset == nil ? nil : (template.models ?? []))
                        .id("\(server.id)-\(program)").disabled(saving)
                }
                if draft != saved.choice {
                    Button(saving ? "Saving…" : "Save helper model") { Task { await save() } }
                        .disabled(saving || (!program.isEmpty && model.isEmpty))
                }
            } else if problem.isEmpty {
                Text("Loading…").font(.callout)
            }
            if !problem.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.secondary)
                if saved == nil { Button("Try again") { Task { await load() } } }
            }
        }
    }

    @ViewBuilder private var approvalSettings: some View {
        if let saved {
            if let reviewer = saved.commandReviewer {
                SettingBlock(title: "Command reviewer", detail: "Claude reviews the command and working directory in the background. A bot uses its own model and standing instructions. You decide whether the command runs.") {
                    Picker("Reviewer", selection: Binding(get: { saved.reviewerBotId.map { "bot:" + $0 } ?? reviewer }, set: { value in Task { await setReviewer(value) } })) {
                        Text("Off").tag("off")
                        if let id = saved.reviewerBotId, saved.reviewerBots?.contains(where: { $0.id == id }) != true {
                            Text("Selected bot unavailable").tag("bot:" + id)
                        }
                        ForEach(saved.reviewerBots ?? []) { candidate in
                            Text(candidate.label).tag("bot:" + candidate.id)
                        }
                        ForEach(["haiku", "sonnet", "opus"], id: \.self) { model in
                            Text("Claude " + model.capitalized).tag(model)
                        }
                    }.disabled(saving).accessibilityIdentifier("bot.commandReviewer")
                    if let reviewerError { Text(reviewerError).font(.callout).foregroundStyle(AppColor.caution) }
                }
            }
            let reading = store.herdrAgentReadings[bot.id]
            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: Binding(get: { saved.autoMode }, set: { value in Task { await setAuto(value) } })) {
                    Text("Auto mode").font(.headline).foregroundStyle(.primary)
                }
                .toggleStyle(.switch).accessibilityLabel("Auto mode").accessibilityIdentifier("bot.autoMode")
                .disabled(saving || saved.reviewEveryTool == true)
                Text("On by default. The bot works in its sandbox, and automatic review answers requests for wider access, so it does not stop to ask you. Workspace 0.2.40 or later can apply automatic review to the next Codex turn. Claude and Antigravity use this setting on their next launch.")
                    .foregroundStyle(.secondary)
                if let reviewing = saved.reviewEveryTool {
                    let selected = HerdrAgentReading.template(own: store.herdrTemplate(for: bot), shared: nil, in: approvalsOnly ? approvalTemplates : templates).template
                    if reviewing || selected?.supportsToolReview == true {
                        Toggle("Ask before every tool call", isOn: Binding(get: { reviewing }, set: { value in Task { await setReview(value) } }))
                            .toggleStyle(.switch).accessibilityLabel("Ask before every tool call").accessibilityIdentifier("bot.reviewEveryTool").disabled(saving)
                        Text("New Claude sessions and their Claude helpers ask for one decision per tool call in Needs Attention. Other agent programs cannot start while this is on.")
                            .foregroundStyle(.secondary)
                    }
                }
                if store.autoSwitchPending(bot) || reading?.autoRestartPending == true {
                    Label("Launch settings are pending. The next message applies them when this session and its helpers are idle. A prompt already on screen still needs a decision.", systemImage: "clock")
                        .foregroundStyle(.primary)
                }
                if let changed = saved.autoChangedMs, let launch = reading?.session?.createdMs, changed > launch {
                    Text("The saved Auto setting changed after this session started.").foregroundStyle(.secondary)
                }
                if !autoProblem.isEmpty { Text(autoProblem).textSelection(.enabled) }
                Text(reading?.reviewDescription ?? "The running session’s effective reviewer has not been reported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .inspectorCard()
        }
    }

    private func load() async {
        problem = ""
        approvalTemplates = []
        do {
            let result: HerdrClient.BotAgentSettings
            if let preset { result = preset }
            else { result = try await store.herdrClient(for: server).botAgentSettings(for: bot.id) }
            if approvalsOnly, result.reviewEveryTool != nil {
                approvalTemplates = try await store.herdrTemplates(on: server)
            }
            try Task.checkCancellation()
            saved = result
            program = result.choice?.template ?? ""
            model = result.choice?.model ?? ""
        } catch is CancellationError { return } catch HerdrClient.Failure.http(404, _) {
            problem = "Update this server’s SwarmHub workspace to choose a coding model and use Auto mode."
        } catch { problem = error.localizedDescription }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await store.herdrClient(for: server).setHelperModel(draft, for: bot.id, existingAgents: store.herdrExistingAgentNames(for: bot))
            problem = ""
        } catch { problem = error.localizedDescription }
    }

    private func setReviewer(_ model: String) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await store.herdrClient(for: server).setCommandReviewer(model, for: bot.id, existingAgents: store.herdrExistingAgentNames(for: bot))
            reviewerError = nil
        } catch { reviewerError = error.localizedDescription }
    }

    private func setReview(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let client = try store.herdrClient(for: server)
            let names = store.herdrExistingAgentNames(for: bot)
            saved = try await client.setToolReview(enabled, for: bot.id, existingAgents: names)
            bot.requiresToolReview = enabled
            store.save()
            await store.approvalSettingsChanged(bot, client: client, names: names)
            autoProblem = ""
        } catch { autoProblem = error.localizedDescription }
    }

    private func setAuto(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await store.applyProjectAutoMode(enabled, for: bot, on: server)
            autoProblem = ""
        } catch { autoProblem = error.localizedDescription }
    }
}

private struct HelperModelPicker: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let template: HerdrClient.Template
    @Binding var model: String
    var preset: [HerdrClient.Template.Model]? = nil
    @State private var models: [HerdrClient.Template.Model] = []
    @State private var problem = ""

    var body: some View {
        Picker("Model", selection: $model) {
            Text("Choose a model").tag("")
            if !model.isEmpty && !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            ForEach(models, id: \.id) { Text(HerdrAgentReading.name($0)).tag($0.id) }
        }.accessibilityLabel("Helper model").tint(Color(nsColor: .secondaryLabelColor))
        .task(id: "\(server.id)-\(template.name)") { await load() }
        if !problem.isEmpty {
            Text(problem).font(.callout).foregroundStyle(.secondary)
            Button("Reload models") { Task { await load() } }
        }
    }

    private func load() async {
        do {
            if let preset { models = preset }
            else { models = try await store.herdrClient(for: server).models(for: template) }
            problem = models.isEmpty ? "This AI lists no models." : ""
        } catch {
            models = template.models ?? []
            problem = error.localizedDescription
        }
    }
}
