import AppKit
import SwarmHubCore
import SwiftUI

/// P2c: Settings → Advanced → About shows the box updater package's expected SHA-256 and exports the package for the
/// operator's own transfer to a box (console or SSH). Reads only the app's resources: no network, no box, no model turn.
struct BootstrapExportSection: View {
    @State private var updaterPackage = BootstrapPackage.locate()
    @State private var baseline = EmbeddedBaseline.locate(BotManagerText.candidates("Baseline"), target: "mac")
    @State private var message: String?

    var body: some View {
        Section("Box updater package") {
            if let updaterPackage {
                LabeledContent("File", value: updaterPackage.fileName)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expected SHA-256").font(.caption).foregroundStyle(.secondary)
                    Text(updaterPackage.expectedDigest).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Button("Export…") { export(updaterPackage) }
                Text("Copy the file to the box yourself. Before installing, run \(updaterPackage.checkCommands().joined(separator: " or ")) there and compare the result with the value above. Never take this value from a chat.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            } else {
                Text("This build has no box updater package.").foregroundStyle(.secondary)
            }
            if let baseline { LabeledContent("Built-in bundle", value: "\(baseline.label) (\(baseline.bundleVersion))") }
        }
    }

    private func export(_ updaterPackage: BootstrapPackage) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Export"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let url = try updaterPackage.export(to: folder)
            message = "Exported \(url.path) (SHA-256 \(updaterPackage.expectedDigest))."
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
}
