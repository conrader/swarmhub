import SwiftUI

/// Settings → Advanced → Orientation (P49): whether a newly created bot orients itself, which bot it reports its first job
/// to, and the quiet hours its orientation names (Mac time zone). SwarmHub states the quiet hours; it holds nothing back.
struct SettingsOrientationPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section("New bots") {
            Toggle("Orientation for new bots", isOn: Binding(get: { store.orientationEnabledSetting }, set: { store.orientationEnabledSetting = $0 }))
            Picker("Coordinator", selection: Binding(get: { store.orientationCoordinatorChoice }, set: { store.orientationCoordinatorChoice = $0 })) {
                Text(OrientationSettingsCopy.automatic(store.defaultCoordinator(for: nil)?.name)).tag(OrientationCoordinatorChoice.automatic)
                ForEach(store.coordinatorCandidates) { bot in Text(bot.name).tag(OrientationCoordinatorChoice.bot(bot.id)) }
                Text("None: reports go to you only").tag(OrientationCoordinatorChoice.none)
            }.disabled(!store.orientationEnabledSetting)
            Text(OrientationSettingsCopy.explain).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("orientation.newBots")
        Section("Quiet hours") {
            HStack {
                hourPicker("From", value: Binding(get: { store.quietHours.start }, set: { store.quietHours.start = $0 }))
                hourPicker("to", value: Binding(get: { store.quietHours.end }, set: { store.quietHours.end = $0 }))
            }
            Text(OrientationSettingsCopy.quiet(store.heartbeatTimeZone)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("orientation.quietHours")
    }

    private func hourPicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) { ForEach(0..<24, id: \.self) { Text(QuietHours.clock($0 * 60)).tag($0 * 60) } }
    }
}

enum OrientationSettingsCopy {
    static func automatic(_ name: String?) -> String { "Default (\(name ?? "none yet"))" }
    static let explain = "A bot the manager creates, or a new bot from a Grok import, sends one first message: it greets you, starts a read-only first job in its area, tells its coordinator and says when it will report. Once per bot; bots you only connect never get one. The default coordinator is the bot named Jarvis if there is exactly one, else the manager bot."
    static func quiet(_ zone: TimeZone) -> String {
        "In this Mac's time zone (\(zone.identifier)). A new bot's orientation tells it not to message you in these hours; SwarmHub does not hold messages back itself."
    }
}
