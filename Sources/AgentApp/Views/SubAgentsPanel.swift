import SwiftUI

struct SubAgentsPanel: View {
    let tasks: [SubAgentTask]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SUB-AGENTS").font(.caption.bold()).foregroundStyle(.secondary).padding()
            Divider()
            if tasks.isEmpty { ContentUnavailableView("No sub-agents", systemImage: "person.2", description: Text("Spawned tasks appear here.")) }
            else { List(tasks) { task in HStack(alignment: .top) {
                Image(systemName: icon(task.status)).foregroundStyle(task.status == .completed ? .green : .blue)
                VStack(alignment: .leading) { Text(task.title).font(.callout.bold()); Text(task.detail).font(.caption).foregroundStyle(.secondary); Text(task.status.rawValue.capitalized).font(.caption2).foregroundStyle(.tertiary) }
            }}.listStyle(.sidebar) }
        }.frame(minWidth: 220, idealWidth: 250).background(.ultraThinMaterial)
    }
    private func icon(_ status: SubAgentStatus) -> String { status == .completed ? "checkmark.circle.fill" : status == .failed ? "xmark.circle.fill" : "sparkles" }
}
