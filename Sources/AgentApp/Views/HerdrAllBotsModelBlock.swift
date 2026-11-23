import SwiftUI

/// Settings → Servers: one agent program and model for every bot on the chosen server at once, which a bot's own
/// Details otherwise sets one bot at a time. What was changed stays here with Undo and "Start fresh agents"
/// (`HerdrModelRecordRow`), as it does in the main bot's chat when the main bot was asked for the same.
struct HerdrAllBotsModelBlock: View {
    @EnvironmentObject private var store: AppStore
    let server: HerdrServer
    @State private var templates: [HerdrClient.Template] = []
    @State private var template = ""
    @State private var model = HerdrModelChoice.recommended
    @State private var models: [HerdrClient.Template.Model] = []
    @State private var open = false
    @State private var note = ""
    @State private var applying = false

    private var effective: HerdrClient.Template? { templates.first { $0.name == template } ?? templates.first }

    var body: some View {
        let count = store.herdrModelTargets(on: server, templates: templates).count, record = store.herdrModelRecord(by: nil, on: server)
        Group {
            if count > 1, !templates.isEmpty {
                SettingBlock(title: "All bots on \(server.name)", detail: "Put every bot on this server on one AI and model at once.") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let record { HerdrModelRecordRow(record: record, title: "Switched \(AppStore.botCount(record.changes.count)) to \(record.label)") }
                        DisclosureGroup("Choose an AI and model", isExpanded: $open) {
                            VStack(alignment: .leading, spacing: 10) {
                                HerdrTemplatePicker(selection: $template, templates: templates, defaultName: nil, defaultNote: "")
                                if let effective, effective.takesModel {
                                    HerdrModelPicker(model: $model, program: effective.modelAgent ?? effective.programName, models: models)
                                }
                                HStack(spacing: 10) {
                                    Button("Set for all \(count) bots") { Task { await apply() } }.buttonStyle(.appleProminent).disabled(effective == nil || applying)
                                    if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                }
                            }.padding(.top, 6)
                        }
                    }
                }
            }
        }
        .task(id: server.id) {
            templates = (try? await store.herdrTemplates(on: server)) ?? []
            if !templates.contains(where: { $0.name == template }) { template = templates.first?.name ?? "" }
        }
        .task(id: template) {
            model = HerdrModelChoice.recommended; note = ""
            guard let effective, effective.takesModel else { models = []; return }
            models = (try? await store.herdrClient(for: server).models(for: effective)) ?? effective.models ?? []
        }
    }

    private func apply() async {
        guard let effective, !applying else { return }
        applying = true
        defer { applying = false }
        // The agents that run now hold their conversations; each bot's next agent is handed its chat.
        let running = await store.herdrRunningLaunches(on: server)
        let chosen = effective.takesModel ? model : HerdrModelChoice.recommended
        let named = chosen == HerdrModelChoice.recommended ? HerdrModelPlan.recommendedLabel : models.first(where: { $0.id == chosen }).map { HerdrAgentReading.name($0) } ?? chosen
        let label = "\(effective.label) · \(named)"
        if store.setHerdrModelForAll(on: server, template: effective, model: chosen, label: label, templates: templates, running: running) == nil {
            note = "Every bot here already runs on \(label)."
        } else { note = ""; open = false }
    }
}
