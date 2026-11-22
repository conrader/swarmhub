import SwiftUI

/// Read-only "Grok history" archive shown above the live chat. Collapsed by default; the archive file
/// is loaded only when expanded. Used for a bot's chat and for a group (archive keyed by the group id).
/// A bot's archive is also handed to its agent (`AppStore+GrokHandoff.swift`): a line under the header says how far
/// that is, with the bot's switch for it. A group's archive is not handed over and has no such line.
struct GrokHistoryView: View {
    @EnvironmentObject private var store: AppStore
    let archiveID: UUID; let count: Int; let ownerName: String
    /// The bot whose agent gets this archive; nil for a group.
    let handoffBotID: UUID?
    @State private var expanded: Bool
    @State private var query = ""

    init(bot: Bot, expanded: Bool = false) { self.init(archiveID: bot.id, count: bot.grokHistoryCount, ownerName: bot.name, expanded: expanded, handoffBotID: bot.id) }
    init(archiveID: UUID, count: Int, ownerName: String, expanded: Bool = false, handoffBotID: UUID? = nil) {
        self.archiveID = archiveID; self.count = count; self.ownerName = ownerName; self.handoffBotID = handoffBotID
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Image(systemName: "archivebox").font(.system(size: 12))
                    Text("Grok history").font(.system(size: 12, weight: .semibold))
                    Text("\(count) messages").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Imported from Grok Bot").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let bot = store.bots.first(where: { $0.id == handoffBotID }), store.grokHandoffApplies(to: bot) { GrokHandoffLine(bot: bot) }
            if expanded {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search Grok history", text: $query).textFieldStyle(.plain) }
                    .font(.system(size: 12)).padding(7).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 7))
                let rows = store.grokHistory.messages(for: archiveID).filter { $0.matches(query.trimmingCharacters(in: .whitespaces)) }
                if rows.isEmpty { Text(query.isEmpty ? "No imported messages." : "No matches.").font(.caption).foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 6) { ForEach(rows) { ArchivedMessageRow(message: $0, botName: ownerName) } }
            }
        }
        .padding(12).background(AppColor.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 24).padding(.bottom, 12)
        .task(id: archiveID) { UISmokeProbe.historyHeaders[archiveID] = count }
    }
}

/// How far the bot's agent has this history, a way to ask for it again after it failed, and the switch that keeps
/// it from the agent.
private struct GrokHandoffLine: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 12)
            Text(store.grokHandoffLine(for: bot)).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            // The person's own request, after the app stopped trying by itself.
            if store.grokOffersRetry(for: bot) {
                Button(GrokHandoffCopy.tryAgain) { store.retryGrokHandoff(for: bot) }.buttonStyle(.link).font(.system(size: 11))
            } else if store.grokOffersSummary(for: bot) {
                Button(GrokHandoffCopy.trySummary) { Task { _ = await store.retryGrokSummary(for: bot) } }.buttonStyle(.link).font(.system(size: 11))
            }
            Toggle(GrokHandoffCopy.switchLabel(bot.name), isOn: Binding(get: { store.grokHandsOver(bot) }, set: { store.setGrokHandsOver($0, for: bot) }))
                .labelsHidden().toggleStyle(.appleSwitch).controlSize(.small)
                .help(GrokHandoffCopy.switchHelp(bot.name))
        }
    }
}

private struct GrokHistoryExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Opens the Grok history archive on first appearance (used by headless snapshots).
    var grokHistoryExpanded: Bool { get { self[GrokHistoryExpandedKey.self] } set { self[GrokHistoryExpandedKey.self] = newValue } }
}

private struct ArchivedMessageRow: View {
    @Environment(\.timeZone) private var timeZone
    let message: ArchivedMessage; let botName: String
    private var heading: String {
        if message.channel == "agent" { return "\(message.author ?? "Agent") → \(message.to ?? "Agent")" }
        switch message.role { case "user": return "You"; case "system": return "System"; default: return message.author ?? botName }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(heading).font(.system(size: 11, weight: .semibold))
                if message.hidden { Text("hidden prompt").font(.system(size: 10)).padding(.horizontal, 5).background(AppColor.raised, in: Capsule()) }
                if let date = message.timestamp { Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Text(message.text).font(.system(size: 12)).textSelection(.enabled).foregroundStyle(message.role == "system" || message.channel != "chat" ? .secondary : .primary)
        }
        .opacity(message.hidden ? 0.6 : 1)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? AppColor.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
