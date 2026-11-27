import SwiftUI

struct SampleInspector: View {
    @ObservedObject var bot: Bot
    let profile: SampleBotProfile
    let tab: AgentInfoTab

    @ViewBuilder var body: some View {
        switch tab {
        case .overview:
            BotInstructions(text: bot.persona == Bot.defaultPersona ? profile.instructions : bot.outboundPersona)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Context & spend").accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(profile.contextPercent)% ctx").monospacedDigit()
                }.font(.caption.weight(.semibold))
                ContextUsageMeter(percent: profile.contextPercent)
                HStack {
                    Text(verbatim: profile.spend)
                    Spacer()
                    Text("Sample usage")
                }.font(.caption)
            }.foregroundStyle(.secondary)
            Divider()
            tags("Projects", profile.projects)
        case .approvals:
            tags("Control level", [profile.controlLevel, "Reviewer: " + profile.reviewer])
            Divider()
            rows("Scoped rules", profile.rules)
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
        Menu {
            Picker("Sample model", selection: Binding(get: { selection }, set: { model in
                bot.sampleModel = model
                store.save()
            })) {
                ForEach(profile.models, id: \.self) { Text(verbatim: $0).tag($0) }
            }.pickerStyle(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: selection)
                Text("\(profile.contextPercent)% ctx").foregroundStyle(.secondary)
            }.font(.caption).lineLimit(1)
        }.fixedSize().controlSize(.small)
            .accessibilityLabel("Choose sample model for " + bot.name)
            .accessibilityValue(selection)
    }
}
