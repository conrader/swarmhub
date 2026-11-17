import SwiftUI

/// What a reply asked the app for (a ```swarmhub fence), as one quiet line in plain words under the reply:
/// "Suggested a new bot: Research". The block itself is never drawn; what came of it shows where the person acts on
/// it (the card above the message box, the other bot's chat). Copy original copies the raw block, for a bug report.
struct FoldedBlockLine: View {
    let line: SwarmhubSummary.Line
    var body: some View {
        Label(line.summary, systemImage: line.symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            .accessibilityLabel(line.summary)
            .contextMenu {
                Button("Copy") { copyToPasteboard(line.summary) }
                Button("Copy original") { copyToPasteboard("```swarmhub\n" + line.block + "\n```") }
            }
    }
}
