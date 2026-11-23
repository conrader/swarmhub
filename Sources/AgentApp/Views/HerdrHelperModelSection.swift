import SwiftUI

struct HerdrHelperModelSection: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    let server: HerdrServer
    let templates: [HerdrClient.Template]

    @State private var saved: HerdrClient.BotAgentSettings?
    @State private var program = ""
    @State private var model = ""
    @State private var saving = false
    @State private var problem = ""

    private var programs: [HerdrClient.Template] { HerdrHelperPolicyDraft.templates(in: templates) }
    private var draft: HerdrHelperPolicy.Tier? { program.isEmpty ? nil : .init(template: program, model: model) }

    var body: some View {
        SettingBlock(title: "Coding model", detail: "Used by new helper agents that \(bot.name) spawns.") {
            if let saved {
                Picker("Helper AI", selection: Binding(get: { program }, set: { program = $0; model = ""; problem = "" })) {
                    Text("Server settings by difficulty").tag("")
                    if !program.isEmpty && !programs.contains(where: { $0.name == program }) { Text(program).tag(program) }
                    ForEach(programs, id: \.name) { item in
                        Text(HerdrProgramName.labels(for: programs)[item.name] ?? item.label).tag(item.name)
                    }
                }.disabled(saving)
                if let template = programs.first(where: { $0.name == program }) {
                    HelperModelPicker(server: server, template: template, model: $model)
                        .id("\(server.id)-\(program)").disabled(saving)
                }
                if draft != saved.choice {
                    Button(saving ? "Saving…" : "Save coding model") { Task { await save() } }
                        .disabled(saving || (!program.isEmpty && model.isEmpty))
                }
            } else if problem.isEmpty {
                Text("Loading…").font(.callout)
            }
            if !problem.isEmpty {
                Text(problem).font(.callout).foregroundStyle(.secondary)
                if saved == nil { Button("Try again") { Task { await load() } } }
            }
        }.task(id: "\(bot.id)-\(server.id)") { await load() }
        if let saved {
            SettingSwitch(title: "Auto mode", detail: "With the standard Claude and Codex setups, new agents and helpers can edit, build and test in their workspace. Broader access may still need approval.",
                          isOn: Binding(get: { saved.autoMode }, set: { value in Task { await setAuto(value) } }))
                .disabled(saving)
        }
    }

    private func load() async {
        problem = ""
        do {
            let result = try await store.herdrClient(for: server).botAgentSettings(for: bot.id)
            saved = result
            program = result.choice?.template ?? ""
            model = result.choice?.model ?? ""
        } catch HerdrClient.Failure.http(404, _) {
            problem = "Update this server’s SwarmHub workspace to choose a coding model and use Auto mode."
        } catch { problem = error.localizedDescription }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await store.herdrClient(for: server).setHelperModel(draft, for: bot.id, existingAgents: existingAgents)
            problem = ""
        } catch { problem = error.localizedDescription }
    }

    private var existingAgents: [String] {
        // Older workspace launches have no stored bot ID. Include their direct and group names.
        let direct = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
        let groups = store.groups.filter { $0.memberIDs.contains(bot.id) }.compactMap { group in
            let session = group.session(for: bot.id) ?? store.sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
            return HerdrBackend.groupRuntimeName(sessionID: session, botID: bot.id)
        }
        return [direct] + groups
    }

    private func setAuto(_ enabled: Bool) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await store.herdrClient(for: server).setProjectAutoMode(enabled, for: bot.id, existingAgents: existingAgents)
            problem = ""
        } catch { problem = error.localizedDescription }
    }
}

private struct HelperModelPicker: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    let template: HerdrClient.Template
    @Binding var model: String
    @State private var models: [HerdrClient.Template.Model] = []
    @State private var problem = ""

    var body: some View {
        Picker("Helper model", selection: $model) {
            Text("Choose a model").tag("")
            if !model.isEmpty && !models.contains(where: { $0.id == model }) { Text(model).tag(model) }
            ForEach(models, id: \.id) { Text(HerdrAgentReading.name($0)).tag($0.id) }
        }.task(id: "\(server.id)-\(template.name)") { await load() }
        if !problem.isEmpty {
            Text(problem).font(.callout).foregroundStyle(.secondary)
            Button("Reload models") { Task { await load() } }
        }
    }

    private func load() async {
        do {
            models = try await store.herdrClient(for: server).models(for: template)
            problem = models.isEmpty ? "This AI lists no models." : ""
        } catch {
            models = template.models ?? []
            problem = error.localizedDescription
        }
    }
}
