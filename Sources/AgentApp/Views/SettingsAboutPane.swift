import SwiftUI

/// Settings → About, under the version and the way to Software Update (`UpdateCheckRow`): this build's identity and
/// the acknowledgements. Everything else about updates is in Software Update (`SoftwareUpdatePane`).
struct SettingsAboutPane: View {
    private let info = AppBuildInfo.current()

    var body: some View {
        Section {
            LabeledContent("Build", value: info.shortSHA.map { $0 + (info.dirty ? " (uncommitted changes)" : "") } ?? "not packaged")
            Text("Releases: github.com/\(AppConstants.releasesRepo)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        AcknowledgementsSection()
    }
}
