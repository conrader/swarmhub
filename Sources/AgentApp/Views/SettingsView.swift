import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    private enum Pane: String, CaseIterable, Identifiable { case account = "Account", appearance = "Appearance", notifications = "Notifications", computers = "Computers", review = "Auto-review", usage = "Usage", updates = "Updates"; var id: String { rawValue }; var icon: String { switch self { case .account: "person.crop.circle"; case .appearance: "paintpalette"; case .notifications: "bell"; case .computers: "desktopcomputer"; case .review: "checkmark.shield"; case .usage: "chart.bar"; case .updates: "arrow.triangle.2.circlepath" } } }
    @State private var pane = Pane.account
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference; @AppStorage("accent") private var accent = AppTheme.defaultAccent; @AppStorage("notifications") private var notifications = false
    var body: some View {
        NavigationSplitView { List(Pane.allCases, selection: $pane) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }.navigationSplitViewColumnWidth(170) } detail: { Form { content }.formStyle(.grouped).navigationTitle(pane.rawValue) }
            .frame(width: 760, height: 560).background(AppColor.panel).tint(AppTheme.accentColor(for: accent))
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .account: SettingsAccountPane()
        case .appearance:
            Picker("Theme", selection: $appearance) { Text("Dark").tag("Dark"); Text("Light").tag("Light"); Text("System").tag("System") }.pickerStyle(.segmented)
            Picker("Accent", selection: $accent) {
                ForEach(AppTheme.accentNames, id: \.self) { name in HStack { Circle().fill(AppTheme.accentColor(for: name)).frame(width: 10, height: 10); Text(name) }.tag(name) }
            }
            Text("Dark is the default. The accent colours buttons, selections and usage bars; Graphite follows the text colour.").font(.caption).foregroundStyle(.secondary)
        case .notifications:
            Section {
                Toggle("Notify about new messages", isOn: $notifications).onChange(of: notifications) { _, enabled in
                    guard enabled, Bundle.main.bundleIdentifier != nil else { return }
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
                Text("Sent when a reply or a routine result arrives while \(AppConstants.name) is in the background.").font(.caption).foregroundStyle(.secondary)
                if Bundle.main.bundleIdentifier == nil { Text("Notifications require running " + AppConstants.name + " from an application bundle.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Per bot") {
                ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in BotNotificationToggle(bot: bot) }
                Text("Muting a bot here is the same as Mute in its sidebar menu or its settings.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!notifications)
        case .computers: SettingsComputersPane()
        case .review:
            Section {
                Text("Approval policy is set per bot: Ask me, ordered allow/deny/ask rules, or another bot as reviewer. Unsafe or destructive commands always come to you. Each bot’s decisions are listed in its Overview panel.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Bots") {
                ForEach(store.bots.filter { !$0.isReadOnlyArchive && !$0.isDemo }) { bot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) { Text(bot.name); Text(reviewSummary(bot)).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Edit…") { store.editingBot = bot }
                    }
                }
            }
        case .usage: SettingsUsagePane()
        case .updates: SettingsUpdatesPane()
        }
    }
    private func reviewSummary(_ bot: Bot) -> String {
        switch bot.approvalMode {
        case .ask: return "Ask me"
        case .rules: return "Rules (\(bot.approvalRules.count))"
        case .reviewer: return "Reviewer: " + (store.bots.first { $0.id == bot.reviewerBotID }?.name ?? "not chosen — asks you")
        }
    }
}

private struct BotNotificationToggle: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        Toggle(bot.name, isOn: Binding(get: { bot.notificationsEnabled }, set: { bot.notificationsEnabled = $0; store.save() }))
    }
}
