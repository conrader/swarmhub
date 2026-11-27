import SwiftUI

struct SampleInspector: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let profile: SampleBotProfile
    let tab: AgentInfoTab

    @ViewBuilder var body: some View {
        switch tab {
        case .overview:
            BotInstructions(text: bot.persona == Bot.defaultPersona ? profile.instructions : bot.outboundPersona, collapsedLines: 6)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context & spend").accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(profile.contextPercent(in: bot))% ctx").monospacedDigit()
                }.font(.caption.weight(.semibold))
                ContextUsageMeter(percent: profile.contextPercent(in: bot))
                HStack {
                    Text(verbatim: profile.spend)
                    Spacer()
                    Text("Sample usage")
                }.font(.caption)
            }.foregroundStyle(.secondary)
            Divider()
            tags("Projects", profile.projects)
        case .model:
            if let model = bot.sampleModelLabel {
                Picker("Model for " + bot.name, selection: Binding(get: { model }, set: { store.selectSampleModel($0, for: bot) })) {
                    ForEach(profile.models, id: \.self) { Text(verbatim: $0).tag($0) }
                }.pickerStyle(.radioGroup)
            }
        case .approvals:
            tags("Control level", [profile.controlLevel, "Reviewer: " + profile.reviewer])
            Divider()
            rows("Scoped rules", profile.rules + (bot.sampleDecision == .allowInProject ? [SampleReview.projectRule] : []))
            if let review = bot.pendingSampleReview {
                Divider()
                SampleReviewCard(bot: bot, review: review)
            }
        case .routines:
            VStack(alignment: .leading, spacing: 6) {
                heading("Routines & triggers")
                Text(verbatim: profile.routine)
                Text(verbatim: profile.schedule).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            tags("Shared skills", profile.skills)
        default: EmptyView()
        }
    }

    private func heading(_ title: String) -> some View {
        Text(verbatim: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func tags(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(title)
            LibraryFlow(spacing: 5) {
                ForEach(items, id: \.self) { InspectorTag(text: $0) }
            }
        }
    }

    private func rows(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            heading(title)
            ForEach(items, id: \.self) { Text(verbatim: $0).font(.callout) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SampleModelPicker: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let profile: SampleBotProfile
    let selection: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(profile.contextPercent(in: bot))% ctx").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Menu {
                Picker("Sample model", selection: Binding(get: { selection }, set: { model in
                    store.selectSampleModel(model, for: bot)
                })) {
                    ForEach(profile.models, id: \.self) { Text(verbatim: $0).tag($0) }
                }.pickerStyle(.inline)
            } label: {
                Text(verbatim: selection).font(.caption)
            }
            .controlSize(.small)
            .accessibilityLabel("Choose sample model for " + bot.name)
            .accessibilityValue(selection)
            .accessibilityIdentifier("chat.sample.model")
            .help("Choose sample model for " + bot.name)
        }.fixedSize()
    }
}

struct SampleReviewCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    let review: SampleReview

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(verbatim: review.title).font(.callout.weight(.semibold))
            Text(verbatim: review.detail).font(.caption).foregroundStyle(.secondary)
            LibraryFlow(spacing: 6) {
                ForEach(review.choices, id: \.self) { decision in
                    Button(decision.title) { store.resolveSampleReview(decision, for: bot) }
                        .controlSize(.small)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
