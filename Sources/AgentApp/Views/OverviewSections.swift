import SwiftUI

/// P32 3: the app never reads or writes the box's memory, so it shows what it has: the summary imported with the
/// agent, or where the memory really is.
struct MemorySection: View {
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory").font(.headline)
            if bot.memorySummary.isEmpty {
                Text(OverviewCopy.memoryOnBox).foregroundStyle(.secondary)
            } else {
                Text(bot.memorySummary).foregroundStyle(.secondary).lineSpacing(2)
                Text(OverviewCopy.memoryImported).font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// P32 2: the chat's `delegate_task` steps, then any `subagent.*` events this session received.
struct DelegatedTasksSection: View {
    @ObservedObject var bot: Bot
    let events: [SubAgentTask]
    var body: some View {
        let tasks = DelegatedTask.tasks(in: bot)
        VStack(alignment: .leading, spacing: 8) {
            Text("Delegated tasks").font(.headline)
            ForEach(tasks) { task in
                row(icon: task.status == .running ? "person.2" : task.status == .failed ? "xmark.circle" : "checkmark.circle",
                    failed: task.status == .failed, title: task.goal, detail: task.detail, status: task.status.rawValue)
            }
            ForEach(events) { task in
                row(icon: task.status == .completed ? "checkmark.circle" : task.status == .failed ? "xmark.circle" : "person.2",
                    failed: task.status == .failed, title: task.title, detail: task.detail, status: task.status.rawValue.capitalized)
            }
            if tasks.isEmpty && events.isEmpty { Text(OverviewCopy.delegatedEmpty).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func row(icon: String, failed: Bool, title: String, detail: String, status: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: icon).foregroundStyle(failed ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.medium)).lineLimit(2)
                if !detail.isEmpty { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(status).font(.caption2).foregroundStyle(.secondary)
        }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The Activity tab's approval policy and its last 20 decisions (moved from Overview, P33).
struct ApprovalAuditSection: View {
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Approval policy").font(.headline); Spacer(); Text(bot.approvalMode.rawValue).font(.caption).foregroundStyle(.secondary) }
            ForEach(bot.approvalAudit.suffix(20).reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(entry.actionKind).font(.caption.weight(.semibold)); Spacer(); Text(entry.outcome.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) }
                    Text("\(entry.decidedBy) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if bot.approvalAudit.isEmpty { Text("Approval requests and decisions will appear here. Command text and arguments are not stored in this audit.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
