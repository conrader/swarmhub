import SwiftUI

/// Which folded lines are open. Memory only: every launch starts folded.
@MainActor final class TechnicalFolds: ObservableObject {
    @Published private(set) var open: Set<String> = []
    func isOpen(_ key: String) -> Bool { open.contains(key) }
    func toggle(_ key: String) { if open.remove(key) == nil { open.insert(key) } }
    /// One ```swarmhub fence of a reply ("<id>#fence<n>").
    nonisolated static func key(_ id: UUID, _ part: String) -> String { id.uuidString + "#" + part }
}

/// A ```swarmhub fence of a reply as one secondary line with a disclosure chevron; unfolded, the block below it.
/// Copy copies the line, Copy original the raw block.
struct FoldedBlockLine: View {
    @ObservedObject var folds: TechnicalFolds
    let key: String; let line: SwarmhubSummary.Line
    var body: some View {
        let open = folds.isOpen(key)
        VStack(alignment: .leading, spacing: 8) {
            Button { folds.toggle(key) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 10)
                    Image(systemName: "gearshape")
                    Text(line.summary).lineLimit(1).truncationMode(.tail)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(open ? "Fold" : "Show the original").accessibilityLabel(line.summary).accessibilityHint(open ? "Folds the original" : "Shows the original")
                .font(.caption).foregroundStyle(.secondary)
            if open {
                Text(SwarmhubSummary.pretty(line.block)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(10).frame(maxWidth: 620, alignment: .leading)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .contextMenu {
            Button("Copy") { copyToPasteboard(line.summary) }
            Button("Copy original") { copyToPasteboard("```swarmhub\n" + line.block + "\n```") }
        }
    }
}
