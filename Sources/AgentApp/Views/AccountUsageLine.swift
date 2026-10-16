import SwiftUI

/// P48: under a connected account in the Connect apps sheet, the bots it is on for (small avatars and names) or "Not
/// used by any bot". Clicking it opens `AccountUsagePopover`, one switch per bot.
struct AccountUsageLine: View {
    let account: ComposioAccount
    let bots: [Bot]
    @ObservedObject var apps: ConnectedAppsStore
    @State var showsBots = false

    var body: some View {
        let using = apps.bots(using: account, among: bots)
        Button { showsBots = true } label: {
            HStack(spacing: 5) {
                if !using.isEmpty {
                    HStack(spacing: -4) { ForEach(using.prefix(4)) { bot in BotAvatar(bot: bot, size: 15) } }
                }
                Text(ConnectedAppsCopy.usedBy(using.map(\.name))).font(.caption).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(using.isEmpty ? .secondary : .primary)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(bots.isEmpty)
        .help("Choose which bots use this account")
        .popover(isPresented: $showsBots, arrowEdge: .bottom) { AccountUsagePopover(account: account, bots: bots, apps: apps) }
    }
}

/// P48: one switch per eligible bot for one account; the same `setAllowed` as Agent access, at most 10 per app.
struct AccountUsagePopover: View {
    let account: ComposioAccount
    let bots: [Bot]
    @ObservedObject var apps: ConnectedAppsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bots using \(account.label)").font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            ForEach(bots) { bot in
                let on = apps.allows(account, botID: bot.id)
                HStack(spacing: 8) {
                    BotAvatar(bot: bot, size: 20); Text(bot.name).font(.callout).lineLimit(1)
                    Spacer(minLength: 12)
                    Toggle(bot.name, isOn: Binding(get: { apps.allows(account, botID: bot.id) }, set: { apps.setAllowed($0, account: account, botID: bot.id) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(apps.busy || !on && !apps.canAllow(account, botID: bot.id))
                }
            }
            if bots.contains(where: { !apps.allows(account, botID: $0.id) && account.isActive && !apps.canAllow(account, botID: $0.id) }) {
                Text(ConnectedAppsCopy.accountsPerAppCap).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 260, alignment: .leading)
    }
}
