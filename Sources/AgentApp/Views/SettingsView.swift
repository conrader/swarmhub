import SwiftUI

/// Settings: the simple page, and "Advanced…" switches the same 760×560 window to the pane list.
/// Pane views are re-homed, not rewritten (`SettingsLayout.AdvancedPane`).
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var advanced = false
    @State private var pane = SettingsLayout.AdvancedPane.servers
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    var body: some View {
        Group {
            if store.isSetupPreview {
                Text(SimpleCopy.previewOff).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if advanced {
                NavigationSplitView {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(SimpleCopy.backToSimple) { advanced = false }.buttonStyle(.link).padding(.horizontal, 14).padding(.vertical, 8)
                        List(SettingsLayout.AdvancedPane.allCases, selection: $pane) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    }.navigationSplitViewColumnWidth(190)
                } detail: {
                    // Servers and keys lays its own groups out; the other panes are grouped forms.
                    if pane == .servers { ScrollView { content.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading) }.navigationTitle(pane.rawValue) }
                    else { Form { content }.formStyle(.grouped).navigationTitle(pane.rawValue) }
                }
            } else {
                SettingsSimplePane(openAdvanced: { advanced = true })
            }
        }
        .frame(width: 760, height: 560).background(AppColor.panel).tint(AppTheme.accentColor(for: accent))
        .onAppear(perform: showRequestedPane).onChange(of: store.settingsPane) { showRequestedPane() }
    }
    private func showRequestedPane() {
        guard let requested = store.settingsPane else { return }
        pane = requested; advanced = true; store.settingsPane = nil
    }
    @ViewBuilder private var content: some View {
        switch pane {
        case .servers: SettingsAccountPane()
        case .alerts: SettingsAlertsPane()
        case .about: SettingsAboutPane()
        case .voice: SettingsVoicePane()
        }
    }
}

/// Opens the Settings window on one Advanced pane (a plain `SettingsLink` opens wherever Settings last was).
struct SettingsPaneButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    let title: String; let pane: SettingsLayout.AdvancedPane
    var body: some View { Button(title) { store.settingsPane = pane; openSettings() } }
}
