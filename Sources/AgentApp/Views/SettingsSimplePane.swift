import SwiftUI
import UserNotifications

/// Settings' simple page (P21 Part A): connection, your name, appearance, notifications, about, and "Advanced…".
/// Every visible string comes from `SimpleCopy`; opening the page makes no network call and reads no key.
struct SettingsSimplePane: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    let openAdvanced: () -> Void
    @AppStorage("appearance") private var appearance = AppTheme.defaultPreference; @AppStorage("accent") private var accent = AppTheme.defaultAccent
    @AppStorage(AppIconAppearance.preferenceKey) private var appIcon = AppIconAppearance.defaultPreference
    @AppStorage("notifications") private var notifications = false
    @AppStorage(UserIdentity.key) private var accountName = ""
    @State private var testLines: [String] = []; @State private var testing = false

    var body: some View {
        Form {
            Section(SimpleCopy.connection) {
                Text(store.connectionStatusLine)
                if store.anyKeyNeedsReentry { Text(SimpleCopy.reenterKey).font(.caption).foregroundStyle(.orange) }
                ForEach(testLines, id: \.self) { line in Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Button(testing ? SimpleCopy.testingConnection : SimpleCopy.testConnection) { test() }.disabled(testing || !store.boxConfigured)
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(store.boxConfigured ? SimpleCopy.changeConnection : SimpleCopy.setUp) { store.openSetup(openWindow: openWindow) }
                }
                Text(SimpleCopy.connectionCaption).font(.caption).foregroundStyle(.secondary)
            }
            Section(SimpleCopy.you) {
                TextField(SimpleCopy.yourName, text: $accountName, prompt: Text(UserIdentity.fallback()))
                Text(SimpleCopy.yourNameCaption).font(.caption).foregroundStyle(.secondary)
            }
            Section(SimpleCopy.appearance) {
                Picker(SimpleCopy.theme, selection: $appearance) { Text(SimpleCopy.dark).tag("Dark"); Text(SimpleCopy.light).tag("Light"); Text(SimpleCopy.system).tag("System") }.pickerStyle(.segmented)
                Picker(SimpleCopy.appIcon, selection: $appIcon) { Text(SimpleCopy.light).tag("Light"); Text(SimpleCopy.dark).tag("Dark") }.pickerStyle(.segmented)
                Picker(SimpleCopy.accent, selection: $accent) {
                    ForEach(AppTheme.accentNames, id: \.self) { name in HStack { Circle().fill(AppTheme.accentColor(for: name)).frame(width: 10, height: 10); Text(name) }.tag(name) }
                }
                Text(SimpleCopy.accentCaption).font(.caption).foregroundStyle(.secondary)
            }
            Section(SimpleCopy.notifications) {
                Toggle(SimpleCopy.notifyMaster, isOn: $notifications).onChange(of: notifications) { _, enabled in
                    guard enabled, Bundle.main.bundleIdentifier != nil else { return }
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
                Text(SimpleCopy.notifyCaption).font(.caption).foregroundStyle(.secondary)
                if Bundle.main.bundleIdentifier == nil { Text(SimpleCopy.notifyNeedsApp).font(.caption).foregroundStyle(.secondary) }
            }
            Section(SimpleCopy.about) { UpdateCheckRow() }
            Section {
                Button(SimpleCopy.advanced, action: openAdvanced)
                Text(SimpleCopy.advancedCaption).font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func test() {
        testing = true; testLines = []
        Task { testLines = await store.testConnectionPlain(); testing = false }
    }
}

/// Version, the automatic check and Check for Updates (Sparkle), or a GitHub check when Sparkle cannot run here.
struct UpdateCheckRow: View {
    @EnvironmentObject private var updater: AppUpdater
    @State private var status: UpdateStatus?; @State private var checking = false
    private let info = AppBuildInfo.current()

    var body: some View {
        LabeledContent(SimpleCopy.version, value: info.version + (info.build.map { " (\($0))" } ?? ""))
        if updater.unavailableReason == nil {
            Toggle(SimpleCopy.autoCheck, isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticallyChecksForUpdates))
            Button(SimpleCopy.checkForUpdates, action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
            Text(SimpleCopy.autoCheckCaption).font(.caption).foregroundStyle(.secondary)
        } else {
            HStack { Button(SimpleCopy.checkNow) { check() }.disabled(checking); if checking { ProgressView().controlSize(.small) } }
            if let status {
                Text(status.message).foregroundStyle(.secondary)
                if case .newer(let release) = status, let page = release.pageURL { Link(SimpleCopy.openRelease(release.name ?? release.tag), destination: page) }
            }
        }
    }

    private func check() {
        checking = true
        Task { status = await ReleaseChecker.check(current: info.version); checking = false }
    }
}
