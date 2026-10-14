import SwiftUI

/// "Add bots from box": paste `profile=key` lines; keys go to the Keychain, each profile is checked, and new bots are
/// named from the profile slug. Shared by Settings → Account and the Grok import's Done step ("Add keys…"), which
/// prefills `<profile>=` lines for the bots that need a key and measures again afterwards (`add`).
struct BoxKeysPasteSection: View {
    @EnvironmentObject private var store: AppStore
    var title = "Add bots from box"
    var prefill = ""
    /// Replaces the plain `addBotsFromBox` call (the Grok Done step re-measures after it).
    var add: ((String) async -> [HermesBotAddResult])?
    @State private var paste = ""
    @State private var results: [HermesBotAddResult] = []
    @State private var adding = false

    var body: some View {
        Section(title) {
            TextEditor(text: $paste).font(.system(.callout, design: .monospaced)).frame(minHeight: 64)
            Text("One profile=key per line (commas also work). Keys are saved to the Keychain, each profile is checked, " +
                 "and new bots are named from the profile slug.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(add == nil ? "Add bots" : "Add keys") { addBots() }.disabled(adding || !hasKey)
                if adding { ProgressView().controlSize(.small) }
            }
            ForEach(results) { result in Text("\(result.label): \(result.summary)").font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { if paste.isEmpty { paste = prefill } }
    }

    /// At least one line with something after its `=`: a bare prefilled `<profile>=` adds nothing.
    private var hasKey: Bool {
        paste.split(whereSeparator: { $0 == "\n" || $0 == "," }).contains { line in
            guard let equals = line.firstIndex(of: "=") else { return !line.trimmingCharacters(in: .whitespaces).isEmpty }
            return !line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func addBots() {
        adding = true
        let text = paste
        paste = ""
        Task {
            results = await (add ?? store.addBotsFromBox)(text)
            adding = false
        }
    }
}
