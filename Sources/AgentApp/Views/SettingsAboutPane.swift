import SwiftUI

/// Settings → Advanced → About: this build's identity, automatic install, why updates are off when they are, and
/// the acknowledgements. Version, the automatic check and Check for Updates live only on the simple page (`UpdateCheckRow`).
struct SettingsAboutPane: View {
    @EnvironmentObject private var updater: AppUpdater
    private let info = AppBuildInfo.current()

    var body: some View {
        Section {
            LabeledContent("Build", value: info.shortSHA.map { $0 + (info.dirty ? " (uncommitted changes)" : "") } ?? "not packaged")
            Text("Releases: github.com/\(AppConstants.releasesRepo)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Section("Updates") {
            if let reason = updater.unavailableReason {
                Text(reason).foregroundStyle(.secondary)
            } else {
                Toggle("Automatically download and install updates", isOn: Binding(get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticallyDownloadsUpdates))
                    .disabled(!updater.allowsAutomaticUpdates)
                Text("When enabled, updates are checked daily. You can install an available update now or let it install when you quit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        AcknowledgementsSection()
    }
}
