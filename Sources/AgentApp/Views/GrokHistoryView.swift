import SwiftUI

/// Read-only "Grok history" archive shown above the live chat. Collapsed by default; the archive file
/// is loaded only when expanded. Used for a bot's chat and for a group (archive keyed by the group id).
/// A bot's archive is also handed to its agent (`AppStore+GrokHandoff.swift`): a line under the header says how far
/// that is, with the bot's switch for it. A group's archive is not handed over and has no such line.
struct GrokHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.transcriptSelection) private var selection
    let archiveID: UUID; let count: Int; let ownerName: String
    /// The bot whose agent gets this archive; nil for a group.
    let handoffBotID: UUID?
    let page: GrokHistoryPage?
    let showPage: ((GrokHistoryPage) -> Void)?
    @State private var expanded: Bool
    @State private var query = ""

    init(bot: Bot, expanded: Bool = false, page: GrokHistoryPage? = nil, showPage: ((GrokHistoryPage) -> Void)? = nil) { self.init(archiveID: bot.id, count: bot.grokHistoryCount, ownerName: bot.name, expanded: expanded, handoffBotID: bot.id, page: page, showPage: showPage) }
    init(archiveID: UUID, count: Int, ownerName: String, expanded: Bool = false, handoffBotID: UUID? = nil, page: GrokHistoryPage? = nil, showPage: ((GrokHistoryPage) -> Void)? = nil) {
        self.archiveID = archiveID; self.count = count; self.ownerName = ownerName; self.handoffBotID = handoffBotID
        self.page = page; self.showPage = showPage
        _expanded = State(initialValue: expanded || page != nil)
    }

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = term.isEmpty ? page : nil
        let rows = archiveRows(matching: term)
        let _ = selection?.showHistory(archiveID, rows: rows.filter { !$0.hidden })
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
                if rows.isEmpty { Text(query.isEmpty ? "No imported messages." : "No matches.").font(.caption).foregroundStyle(.secondary) }
                if let context {
                    if let earlier = context.earlier { Button("Earlier imported messages") { showPage?(earlier) } }
                    VStack(alignment: .leading, spacing: 6) { archivedRows(rows) }
                    if let later = context.later { Button("Later imported messages") { showPage?(later) } }
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) { archivedRows(rows) }
                }
            }
        }
        .padding(12).background(AppColor.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 24).padding(.bottom, 12)
        .task(id: archiveID) { UISmokeProbe.historyHeaders[archiveID] = count }
    }
    private func archiveRows(matching term: String) -> [ArchivedMessage] {
        guard expanded else { return [] }
        if term.isEmpty, let page { return Array(page.rows) }
        let messages = page?.messages ?? store.grokHistory.messages(for: archiveID)
        return term.isEmpty ? messages : messages.filter { $0.matches(term) }
    }

    private func archivedRows(_ rows: [ArchivedMessage]) -> some View {
        ForEach(rows, id: \.dedupeKey) { row in
            ArchivedMessageRow(message: row, botName: ownerName)
                .trackArchiveFocus(page?.key == row.dedupeKey).id(ChatScrollAnchor.imported(row.dedupeKey))
        }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(message.heading(botName: botName)).font(.system(size: 11, weight: .semibold))
                if message.hidden { Text("hidden prompt").font(.system(size: 10)).padding(.horizontal, 5).background(AppColor.raised, in: Capsule()) }
                if let date = message.timestamp { Text(date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: timeZone))).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            TranscriptRunView(run: .init(value: AttributedString(message.text), offset: 0), style: .caption)
                .environment(\.transcriptRow, message.hidden ? nil : .history(message.dedupeKey))
                .font(.system(size: 12)).foregroundStyle(message.role == "system" || message.channel != "chat" ? .secondary : .primary)
        }
        .opacity(message.hidden ? 0.6 : 1)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? AppColor.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
