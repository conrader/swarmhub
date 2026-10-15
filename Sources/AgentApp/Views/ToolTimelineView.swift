import AppKit
import SwiftUI

/// P38 B: a bot's app actions in its Activity tab (newest first): tool, state, account, the arguments sent, an excerpt
/// of the result and the full result to save. Nothing shows until the bot has asked for an app action.
struct ToolTimelineView: View {
    @ObservedObject var apps: ConnectedAppsStore
    let botID: UUID
    var body: some View {
        let rows = Array(apps.receipts.filter { $0.botID == botID }.reversed().prefix(50))
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("App activity").font(.headline); Spacer(); Text("\(rows.count) actions").font(.caption).foregroundStyle(.secondary) }
                ForEach(rows) { receipt in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Account: \(receipt.account)").font(.caption2).foregroundStyle(.secondary)
                            Text(receipt.arguments).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            if let output = receipt.outputExcerpt { Text(output).font(.system(size: 11, design: .monospaced)).lineLimit(8).textSelection(.enabled) }
                            if receipt.state == .unknown { Text("The outcome is unknown. Check the connected app before asking for this action again.").font(.caption2).foregroundStyle(.orange) }
                            if let resultID = receipt.resultID { Button("Save full result…") { export(resultID) }.font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        HStack { Text(receipt.tool).font(.caption.weight(.semibold)); Spacer(); Text(receipt.stateLabel).font(.caption).foregroundStyle(.secondary) }
                    }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private func export(_ id: UUID) {
        do {
            let data = try apps.results().read(id, botID: botID)
            let panel = NSSavePanel(); panel.nameFieldStringValue = "app-result.json"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch { apps.error = error.localizedDescription }
    }
}
