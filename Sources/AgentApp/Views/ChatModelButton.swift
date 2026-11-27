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
        HStack(spacing: 0) {
            Button {
                if let next { choose(next, model: HerdrModelChoice.recommended) }
                else { store.openInfoTab(.model) }
            } label: {
                caption.padding(.horizontal, 7).padding(.vertical, 3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.bot.model")
            .help(next.map { "Switch \(bot.name) to \($0.pickerLabel)" } ?? "Open this bot’s model settings")
            if !templates.isEmpty {
                Divider().frame(height: 13)
                Menu { choices } label: {
                    Image(systemName: "chevron.down").font(.caption2)
                        .frame(width: 23, height: 22).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Choose model for " + bot.name)
                .accessibilityIdentifier("chat.bot.model.choices")
                .help("Choose an AI or model for " + bot.name)
            }
        }
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(AppColor.separator).allowsHitTesting(false) }
        .disabled(applying)
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
                    modelChoice("Recommended", template: template, model: HerdrModelChoice.recommended)
                    let models = template.name == reading?.runtime?.name ? reading?.offeredModels ?? [] : template.models ?? []
                    ForEach(models, id: \.id) { model in
                        modelChoice(HerdrAgentReading.name(model), template: template, model: model.id)
                    }
                }
            } else {
                modelChoice(title, template: template, model: HerdrModelChoice.recommended)
            }
        }
        Divider()
        Button("Model settings…") { store.openInfoTab(.model) }
    }

    private func modelChoice(_ title: String, template: HerdrClient.Template, model: String) -> some View {
        let selected = reading?.runtime?.name == template.name && (template.takesModel ? store.herdrModel(for: bot) == model : true)
        return Button { choose(template, model: model) } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
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
                guard let available = catalog.first(where: { $0.name == template.name }), isAvailable(available) else {
                    failure = "This AI is no longer available for this bot."
                    await store.refreshHerdrAgentReading(for: bot)
                    return
                }
                if model != HerdrModelChoice.recommended {
                    let offered = try await store.herdrClient(for: server).models(for: available)
                    guard offered.contains(where: { $0.id == model }) else {
                        failure = "This AI no longer offers that model."
                        await store.refreshHerdrAgentReading(for: bot)
                        return
                    }
                }
                guard store.selectedBot === bot, store.selectedGroup == nil, !bot.isReadOnlyArchive,
                      store.herdrServer(for: bot) == server, isAvailable(available),
                      previousTemplate == store.herdrTemplate(for: bot), previousModel == store.herdrModel(for: bot) else { return }
                store.setHerdrTemplate(available.name, for: bot)
                store.setHerdrModel(model, for: bot)
                await store.refreshHerdrAgentReading(for: bot)
                if store.launchWorkEnabled { await store.herdrChoiceChanged(for: bot); await store.refreshHerdrAgentReading(for: bot) }
            } catch { failure = error.localizedDescription }
        }
    }
}
