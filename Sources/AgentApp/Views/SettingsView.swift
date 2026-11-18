import SwiftUI

/// Settings: one window, its panes listed at the left as System Settings lists them (`SettingsLayout.Pane`). It
/// opens on General.
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pane = SettingsLayout.Pane.general
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
    var body: some View {
        Group {
            if store.isSetupPreview {
                Text(SimpleCopy.previewOff).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    List(SettingsLayout.Pane.allCases, selection: $pane) { item in
                        Label { Text(item.rawValue) } icon: { SymbolTile(symbol: item.icon, colour: item.colour, size: 22) }.padding(.vertical, 3).tag(item)
                    }.navigationSplitViewColumnWidth(180)
                } detail: {
                    // General, Servers and Software Update lay their own groups out; About is a grouped form.
                    Group {
                        switch pane {
                        case .general: SettingsSimplePane()
                        case .servers: ScrollView { SettingsAccountPane().padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading) }
                        case .vault: HerdrVaultSettings()
                        case .updates: ScrollView { SoftwareUpdatePane().padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading) }
                        case .about: Form { Section { UpdateCheckRow() }; SettingsAboutPane() }.formStyle(.grouped)
                        }
                    }.navigationTitle(pane.rawValue)
                }
            }
        }
        .frame(width: 760, height: 560).background(AppColor.panel).tint(AppTheme.accentColor(for: accent))
        .onAppear(perform: showRequestedPane).onChange(of: store.settingsPane) { showRequestedPane() }
    }
    private func showRequestedPane() {
        guard let requested = store.settingsPane else { return }
        pane = requested; store.settingsPane = nil
    }
}

/// Opens the Settings window on one pane (a plain `SettingsLink` opens wherever Settings last was).
struct SettingsPaneButton: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    let title: String; let pane: SettingsLayout.Pane
    var body: some View { Button(title) { store.settingsPane = pane; openSettings() } }
}
