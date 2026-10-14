import SwiftUI

/// Read-only "Grok history" archive shown above the live chat. Collapsed by default; the archive file
/// is loaded only when expanded. Used for a bot's chat and for a group (archive keyed by the group id).
struct GrokHistoryView: View {
    @EnvironmentObject private var store: AppStore
    let archiveID: UUID; let count: Int; let ownerName: String
    @State private var expanded: Bool
    @State private var query = ""

    init(bot: Bot, expanded: Bool = false) { self.init(archiveID: bot.id, count: bot.grokHistoryCount, ownerName: bot.name, expanded: expanded) }
    init(archiveID: UUID, count: Int, ownerName: String, expanded: Bool = false) {
        self.archiveID = archiveID; self.count = count; self.ownerName = ownerName; _expanded = State(initialValue: expanded)
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

private struct GrokHistoryExpandedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Opens the Grok history archive on first appearance (used by headless snapshots).
    var grokHistoryExpanded: Bool { get { self[GrokHistoryExpandedKey.self] } set { self[GrokHistoryExpandedKey.self] = newValue } }
}

private struct ArchivedMessageRow: View {
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
                if let date = message.timestamp { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Text(message.text).font(.system(size: 12)).textSelection(.enabled).foregroundStyle(message.role == "system" || message.channel != "chat" ? .secondary : .primary)
        }
        .opacity(message.hidden ? 0.6 : 1)
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == "user" ? AppColor.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// Shown instead of the composer when a bot's profile has no key in the Keychain.
struct AddKeyBanner: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var adding = false
    @State private var key = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            if adding {
                SecureField(SimpleCopy.keyFor(bot.name), text: $key).textFieldStyle(.roundedBorder).onSubmit(save)
                Button(SimpleCopy.save, action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(SimpleCopy.cancel) { adding = false; key = "" }
            } else {
                Text(store.keyNeedsReentry(bot) ? KeychainStore.reenterMessage : SimpleCopy.noKey(bot.name)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(SimpleCopy.addKey) { adding = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12).frame(maxWidth: 720).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func save() { store.saveKey(key, for: bot); key = ""; adding = false }
}

/// Shown instead of the composer for a Grok-imported bot with no Hermes profile (`Bot.isGrokHistoryOnly`). P21 D9:
/// plain words, and "Connect…" opens the setup window prefilled with this agent's line instead of Settings.
struct HistoryOnlyBanner: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let bot: Bot
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "archivebox").foregroundStyle(.secondary)
            Text(SimpleCopy.historyOnly).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button(SimpleCopy.connect) { store.openSetup(store.setupPrefill(for: bot), openWindow: openWindow) }
        }
        .padding(12).frame(maxWidth: 720).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
}
