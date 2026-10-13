import SwiftUI

/// Read-only "Grok history" archive shown above the live chat. Collapsed by default; the archive file
/// is loaded only when expanded.
struct GrokHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var expanded = false
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 12)
                    Image(systemName: "archivebox").font(.system(size: 12))
                    Text("Grok history").font(.system(size: 12, weight: .semibold))
                    Text("\(bot.grokHistoryCount) messages").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Imported from Grok Bot").font(.system(size: 11)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search Grok history", text: $query).textFieldStyle(.plain) }
                    .font(.system(size: 12)).padding(7).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 7))
                let rows = store.grokHistory.messages(for: bot.id).filter { $0.matches(query.trimmingCharacters(in: .whitespaces)) }
                if rows.isEmpty { Text(query.isEmpty ? "No imported messages." : "No matches.").font(.caption).foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 6) { ForEach(rows) { ArchivedMessageRow(message: $0, botName: bot.name) } }
            }
        }
        .padding(12).background(AppColor.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
        .padding(.horizontal, 24).padding(.bottom, 12)
    }
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
                SecureField("API key for \(bot.hermesProfile ?? "profile")", text: $key).textFieldStyle(.roundedBorder).onSubmit(save)
                Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { adding = false; key = "" }
            } else {
                Text("No key for \(bot.hermesProfile ?? "this profile") yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Add key") { adding = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12).frame(maxWidth: 720).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24).padding(.vertical, 12)
    }
    private func save() { store.saveKey(key, for: bot); key = ""; adding = false }
}
