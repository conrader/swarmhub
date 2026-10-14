import AppKit
import SwiftUI

/// Settings → Account → Grok Bot (P10d 3): a status line, the last import from the archive dates, and a button that
/// opens the import sheet in the main window (the sheet lives in that window's scene). Hidden when Grok Bot is not on
/// this Mac. Reads no Grok data: the status is the Tier 1 check plus this app's own store.
struct SettingsGrokSection: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if store.grokBotPresent {
            Section("Grok Bot") {
                LabeledContent("Status") { Text(status).foregroundStyle(.secondary) }
                if let last = lastImport {
                    LabeledContent("Last import") { Text(last.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                }
                Button("Import from Grok Bot…") { open() }
                Text("Reads Grok Bot's bots and history on this Mac; All history also asks macOS once for Grok Bot's sign-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var imported: [UUID] {
        store.bots.filter { $0.grokSourceID != nil }.map(\.id) + store.groups.filter { $0.grokSourceID != nil }.map(\.id)
    }

    private var status: String {
        let count = store.bots.filter { $0.grokSourceID != nil }.count
        return count == 0 ? "Found on this Mac; nothing imported yet" : "Found on this Mac; \(count) bots imported"
    }

    /// The newest archive file's date: the archive is the system of record, so no second date is stored.
    private var lastImport: Date? { imported.compactMap { store.grokHistory.lastModified(for: $0) }.max() }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = UISmoke.mainWindow() { window.makeKeyAndOrderFront(nil) } else { openWindow(id: ContentView.windowID) }
        store.showingGrokImport = true
    }
}
