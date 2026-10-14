import SwiftUI

extension ModelRolesPlan: Identifiable { var id: [UUID] { rows.map(\.id) } }

/// Settings → Models → **Switch existing chats…**: from → to per bot or why it is skipped. Nothing is sent before
/// Confirm; then one lock per changing bot, one at a time, with a result per row. Static text, no spinner, no animation.
struct ModelRolesPlanSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let plan: ModelRolesPlan
    @State private var running = false
    @State private var results: [UUID: String]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch existing chats").font(.title3.bold())
            Text("\(plan.countText). Each changing bot's main chat is pinned to the model it resolves to now; group chats and threads are not touched. "
                 + ModelRoleReason.permanent.text).font(.caption).foregroundStyle(.secondary)
            List(plan.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                    Text(row.text).font(.caption).foregroundStyle(row.willChange ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    if let result = results?[row.id] {
                        Text(result).font(.caption).foregroundStyle(result.hasPrefix("switched") ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    }
                }
            }
            HStack {
                if running { Text("Switching…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if results == nil {
                    Button("Cancel") { dismiss() }.disabled(running)
                    Button("Confirm") { confirm() }.buttonStyle(.borderedProminent).disabled(running || plan.changing.isEmpty)
                } else {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20).frame(width: 520, height: 460)
    }

    private func confirm() {
        running = true
        Task { results = await store.runModelRolesPlan(plan); running = false }
    }
}
