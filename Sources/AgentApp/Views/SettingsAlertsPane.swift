import SwiftUI

/// Settings → Advanced → Appearance and alerts (P21): the per-bot notification switches and avatar motion, moved
/// unchanged from the old Notifications and Appearance panes, and each server's off-app alerts. The master switch lives
/// on the simple page.
struct SettingsAlertsPane: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("notifications") private var notifications = false
    var body: some View {
        Section("Per bot") {
            ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in BotNotificationToggle(bot: bot) }
            Text("Muting a bot here is the same as Mute in its sidebar menu or its settings.").font(.caption).foregroundStyle(.secondary)
            if !notifications { Text("Notifications are off on the simple page.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(!notifications)
        AvatarMotionSettingRow()
        // Alerts from each server while SwarmHub is closed (ntfy, email), with the box's service state. rel066: switched off.
        if store.boxAlertsOn { BoxAlertsSection(cache: store.boxAlerts) }
    }
}

private struct BotNotificationToggle: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        Toggle(bot.name, isOn: Binding(get: { bot.notificationsEnabled }, set: { bot.notificationsEnabled = $0; store.save() }))
    }
}
