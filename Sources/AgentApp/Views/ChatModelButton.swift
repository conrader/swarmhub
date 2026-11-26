import SwiftUI

struct ChatModelButton: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var applying = false
    @State private var failure: String?

    private var reading: HerdrAgentReading? { store.herdrAgentReadings[bot.id] }
    private var templates: [HerdrClient.Template] {
        guard let reading, reading.catalogServer == store.herdrServer(for: bot) else { return [] }
        return reading.templates.filter(isAvailable)
    }

    private func isAvailable(_ template: HerdrClient.Template) -> Bool {
        template.error == nil && (!bot.documentReadOnly || template.supportsDocumentReview == true)
            && (bot.sessionCapCents == nil || template.supportsSessionCap == true)
    }

    private var next: HerdrClient.Template? {
        let choices = templates
        guard choices.count > 1 else { return nil }
        let name = store.herdrTemplate(for: bot) ?? reading?.runtime?.name
        guard let index = choices.firstIndex(where: { $0.name == name }) else { return choices.first }
        return choices[(index + 1) % choices.count]
    }

    var body: some View {
        Group {
            if let next {
                Menu { choices } label: { caption } primaryAction: { choose(next, model: HerdrModelChoice.recommended) }
                    .help("Switch " + bot.name + " to " + next.pickerLabel + ". Open the menu to choose a model.")
            } else if let template = templates.first, template.takesModel {
                Menu { choices } label: { caption }
                    .help("Choose a model for " + bot.name)
            } else {
                Button { store.openInfoTab(.model) } label: { caption }
                    .help("Open this bot’s model settings")
            }
        }
        .controlSize(.small).disabled(applying)
        .accessibilityIdentifier("chat.bot.model")
        .alert("Couldn’t switch model", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private var caption: some View {
        let usage = store.herdrPresence(for: bot)?.usage
        return VStack(alignment: .leading, spacing: 2) {
            Text(reading?.headerModel ?? "Model settings")
            if let target = reading?.pendingTarget {
                Text("Next direct turn · \(target)")
            } else if let percent = usage?.contextPercent {
                Text("Context \(percent)%").foregroundStyle(.secondary).monospacedDigit()
            } else if let cost = usage?.estimatedCost {
                Text("Est. \(cost)").foregroundStyle(.secondary).monospacedDigit()
            }
        }.lineLimit(1).font(.caption)
    }

    @ViewBuilder private var choices: some View {
        let labels = HerdrProgramName.labels(for: templates)
        ForEach(templates, id: \.name) { template in
            let title = labels[template.name] ?? template.pickerLabel
            if template.takesModel {
                Menu(title) {
                    Button("Recommended") { choose(template, model: HerdrModelChoice.recommended) }
                    let models = template.name == reading?.runtime?.name ? reading?.offeredModels ?? [] : template.models ?? []
                    ForEach(models, id: \.id) { model in
                        Button(HerdrAgentReading.name(model)) { choose(template, model: model.id) }
                    }
                }
            } else {
                Button(title) { choose(template, model: HerdrModelChoice.recommended) }
            }
        }
        Divider()
        Button("Model settings…") { store.openInfoTab(.model) }
    }

    private func choose(_ template: HerdrClient.Template, model: String) {
        guard !applying else { return }
        let server = store.herdrServer(for: bot)
        let previousTemplate = store.herdrTemplate(for: bot), previousModel = store.herdrModel(for: bot)
        applying = true
        Task {
            defer { applying = false }
            do {
                let catalog = try await store.herdrTemplates(on: server)
                guard store.selectedBot?.id == bot.id, store.selectedGroup == nil, store.herdrServer(for: bot) == server,
                      previousTemplate == store.herdrTemplate(for: bot), previousModel == store.herdrModel(for: bot) else { return }
                guard let available = catalog.first(where: { $0.name == template.name }), isAvailable(available) else {
                    failure = "This AI is no longer available for this bot."
                    await store.refreshHerdrAgentReading(for: bot)
                    return
                }
                store.setHerdrTemplate(available.name, for: bot)
                store.setHerdrModel(model, for: bot)
                await store.refreshHerdrAgentReading(for: bot)
                if store.launchWorkEnabled { await store.herdrChoiceChanged(for: bot); await store.refreshHerdrAgentReading(for: bot) }
            } catch { failure = error.localizedDescription }
        }
    }
}
