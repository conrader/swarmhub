import SwiftUI

/// P22 "Manage bots" (the manager's composer + menu and chat header): each item fills the composer with a plain request.
struct ManageBotsMenu<Label: View>: View {
    let actions: [ManageBotsAction]; let perform: (ManageBotsAction) -> Void; @ViewBuilder let label: () -> Label
    var body: some View {
        Menu {
            Section("Manage bots") {
                ForEach(actions) { action in Button(action.title, systemImage: action.systemImage) { perform(action) } }
            }
        } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            .help("Manage bots").accessibilityLabel("Manage bots")
    }
}

/// Profiles the manager listed that SwarmHub has no bot for, each with Add (derived key + probe; a rejected key → paste it).
/// An OpenClaw manager's offers are Gateway agents; Add binds them directly (P26).
struct BotOffersCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var manager: Bot
    var body: some View {
        let offers = store.botOffers[manager.id] ?? []
        if !offers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(manager.backend == .openClaw ? "On the Gateway" : "On the box"), not in \(AppConstants.name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.botOffers[manager.id] = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
                }
                ForEach(offers) { offer in
                    HStack(spacing: 8) {
                        Text(manager.backend == .openClaw ? offer.name : HermesProfileNaming.botName(forProfile: offer.name)).font(.callout.weight(.medium))
                        Text(offer.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        switch offer.state {
                        case .offered: Button("Add") { Task { await store.addOffered(offer, manager: manager) } }
                        case .adding: ProgressView().controlSize(.small)
                        case .needsKey: SettingsPaneButton(title: "Paste key…", pane: .servers)
                            .help("This bot does not use a derived key; paste profile=key in \(SettingsLayout.path(.servers, "Add bots from box")).")
                        case .unreachable: Button("Retry") { Task { await store.addOffered(offer, manager: manager) } }.help("Couldn’t reach this bot yet.")
                        }
                    }
                }
            }.padding(10).background(AppColor.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
                .padding(.horizontal, 24).frame(maxWidth: 768)
        }
    }
}

/// The bot editor's "Instructions on the box": the last text the manager showed, and on-demand management turns.
struct BoxInstructionsSection: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    @ObservedObject var bot: Bot
    var body: some View {
        if !bot.isReadOnlyArchive, let manager = store.manager(for: bot) {
            let profile = bot.backend == .openClaw ? bot.openClaw?.agentID ?? "" : bot.hermesProfile ?? "default"
            Section("Instructions on the box") {
                if let known = bot.boxInstructions, let text = known.text {
                    ScrollView { Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120)
                    Text(caption(known)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(bot.boxInstructions?.stale == true ? "Changed on the box; not loaded." : "Not loaded.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Load from box") { store.startManagement(.showInstructions, manager: manager, target: profile, send: true); dismiss() }
                    if manager.id != bot.id {
                        Button("Ask \(manager.name) to change…") { store.startManagement(.changeInstructions, manager: manager, target: profile); dismiss() }
                    }
                }
            }
        }
    }
    private func caption(_ known: BoxInstructions) -> String {
        let time = known.fetchedAt.map { "Loaded \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Loaded"
        return known.stale ? "\(time) · changed on the box since" : time
    }
}
