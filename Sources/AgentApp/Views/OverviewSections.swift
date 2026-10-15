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

/// The Activity tab's approval lines and its last 20 decisions (moved from Overview, P33), with the matched line and
/// the deciding reviewer (P37), then the reviews of this bot's replies.
struct ApprovalAuditSection: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("Approvals").font(.headline); Spacer(); Text(policy).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            ForEach(bot.approvalAudit.filter { $0.actionKind != "review" }.suffix(20).reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        if let reviewer = reviewer(entry.decidedBy) { BotAvatar(bot: reviewer, size: 14) }
                        Text(entry.actionKind).font(.caption.weight(.semibold)); Spacer(); Text(entry.outcome.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(decider(entry.decidedBy)) · \(entry.timestamp.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                    if let rule = entry.rule { Text(rule).font(.caption2).foregroundStyle(.secondary) }
                    Text(entry.reason).font(.caption2).foregroundStyle(.secondary)
                }.padding(8).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            }
            if bot.approvalAudit.isEmpty { Text("Approval requests and decisions will appear here. Command text and arguments are not stored in this audit.").font(.caption).foregroundStyle(.secondary) }
            let reviews = store.reviewCards(of: bot)
            if !reviews.isEmpty {
                Text("Reviews").font(.headline).padding(.top, 6)
                ForEach(reviews.prefix(20)) { card in
                    HStack(spacing: 6) {
                        if let reviewer = card.metadata[ReviewKey.reviewer].flatMap(UUID.init(uuidString:)).flatMap({ id in store.bots.first { $0.id == id } }) { BotAvatar(bot: reviewer, size: 14) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.content).font(.caption.weight(.semibold))
                            Text([card.metadata[ReviewKey.why].map { "After it \($0)" }, card.createdAt.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
    private var policy: String {
        let routing = bot.effectiveRouting
        return "\(routing.lines.count) own line\(routing.lines.count == 1 ? "" : "s") · \(store.globalApprovalRoutes.count) for all bots"
    }
    private func reviewer(_ decidedBy: String) -> Bot? {
        guard decidedBy.hasPrefix("reviewer:"), let id = UUID(uuidString: String(decidedBy.dropFirst(9))) else { return nil }
        return store.bots.first { $0.id == id }
    }
    private func decider(_ decidedBy: String) -> String {
        if let reviewer = reviewer(decidedBy) { return "Reviewer \(reviewer.name)" }
        if decidedBy.hasPrefix("rule:") { return "Rule" }
        return decidedBy == "user" ? "You" : decidedBy == "system" ? AppConstants.name : decidedBy
    }
}
