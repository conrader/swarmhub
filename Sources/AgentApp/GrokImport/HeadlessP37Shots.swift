import AppKit
import SwiftUI

/// P37 shots of `--render-setup`: a bot's approval lines and review-after lines in its editor, Settings → Approvals with
/// "anything → Reviewer: Jarvis" for all bots, an approval Jarvis decided (and one it escalated), a review card with
/// changes requested, and the Activity tab listing approvals and reviews. Throwaway in-memory store; no network.
@MainActor enum HeadlessP37Shots {
    static let names = ["p37-bot-rule-editor", "p37-settings-approvals", "p37-approval-decided-by-reviewer", "p37-review-card-changes", "p37-activity-approvals-reviews"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.botMessages.autoLoad = false
        let jarvis = Bot(name: "Jarvis", title: "Chief of staff", backend: .hermes, hermesProfile: "grok-jarvis")
        let coder = Bot(name: "Coder", title: "Writes and fixes code", backend: .hermes, hermesProfile: "coder")
        let infra = Bot(name: "Infra", title: "Servers and backups", backend: .hermes, hermesProfile: "grok-infra")
        jarvis.avatarName = .allCases[0]; coder.avatarName = .allCases[min(6, BotAvatarName.allCases.count - 1)]; infra.avatarName = .allCases[min(3, BotAvatarName.allCases.count - 1)]
        store.bots = [jarvis, coder, infra]
        store.globalApprovalRoutes = [.anything(.reviewer, reviewer: jarvis.id)]
        store.globalReviewAfter = [ReviewAfterRule(trigger: .codingJob, reviewerID: jarvis.id)]
        coder.approvalRouting = ApprovalRouting(lines: [
            ApprovalRoute(kind: .command, commandPattern: "git push*", decision: .ask),
            ApprovalRoute(kind: .command, commandPattern: "*deploy*", decision: .deny),
            ApprovalRoute(kind: .botMessage, targetBot: "grok-infra", decision: .reviewer, reviewerID: infra.id),
            ApprovalRoute(kind: .command, commandPattern: "git status*", decision: .approve)
        ], otherwise: .anything(.ask))
        coder.reviewAfter = [ReviewAfterRule(trigger: .codingJob, reviewerID: jarvis.id, autoSendNotes: false),
                             ReviewAfterRule(trigger: .botMessage, botMessageTo: "grok-infra", reviewerID: infra.id, autoSendNotes: true)]

        let now = Date.now, start = now.addingTimeInterval(-600)
        let reply = ChatMessage(role: .assistant, content: "The export now streams rows instead of building the whole CSV first; 40 s → 3 s on the sample.\n\ncode-job: claude done · waited 0s · ran 41s · peak 210 MB\n3 files changed, 48 insertions(+), 19 deletions(-)",
                                createdAt: start.addingTimeInterval(60), turnState: .finished)
        var activity = ToolActivity()
        activity.apply(ToolEvent(phase: .started, name: "read_file", preview: "src/export.py", callID: "1"), at: start)
        activity.apply(ToolEvent(phase: .completed, name: "read_file", callID: "1"), at: start.addingTimeInterval(1))
        activity.apply(ToolEvent(phase: .started, name: "terminal", preview: "code-job --bot coder --order claude,codex", callID: "2"), at: start.addingTimeInterval(2))
        activity.apply(ToolEvent(phase: .completed, name: "terminal", callID: "2"), at: start.addingTimeInterval(43))
        activity.finish(at: start.addingTimeInterval(45)); reply.activity = activity
        let review = ChatMessage(role: .system, content: "Jarvis: changes requested", createdAt: start.addingTimeInterval(90), presentation: .review,
                                 metadata: [ReviewKey.reviewer: jarvis.id.uuidString, ReviewKey.state: "changes", ReviewKey.reply: reply.id.uuidString, ReviewKey.why: "finished a coding job",
                                            ReviewKey.notes: "The streaming writer never closes the file when a row fails. Wrap it in a `with` block and add a test for an export that stops half-way."])
        let decided = ChatMessage(role: .system, content: "Approved automatically: Run git log", createdAt: start.addingTimeInterval(-60), presentation: .approvalDecision,
                                  metadata: [ApprovalCardKey.outcome: "approved", ApprovalCardKey.decider: jarvis.id.uuidString, ApprovalCardKey.rule: "All bots line 1: Anything → Reviewer: Jarvis"])
        coder.messages = [ChatMessage(role: .user, content: "show me what changed in the export since Monday", createdAt: start.addingTimeInterval(-90)),
                          decided,
                          ChatMessage(role: .assistant, content: "Three commits touched the export; the slow part is building the whole CSV in memory. I'll fix it with a coding job.", createdAt: start.addingTimeInterval(-50), turnState: .finished),
                          ChatMessage(role: .user, content: "go ahead", createdAt: start.addingTimeInterval(-10)), reply, review]
        let approvalID = UUID()
        store.approvals = [ApprovalRequest(id: approvalID, title: "Run git push", summary: "git push origin export-streaming", draft: nil, command: "git push origin export-streaming",
                                           botID: coder.id, rule: "All bots line 1: Anything → Reviewer: Jarvis",
                                           routeNote: "Unsafe, destructive, or unparseable operations always require user review.", reviewerID: jarvis.id)]
        for (kind, outcome, by, rule, reason) in [("command", ApprovalAuditOutcome.approved, "reviewer:\(jarvis.id.uuidString)", "All bots line 1: Anything → Reviewer: Jarvis", "Reviewer Jarvis approved."),
                                                  ("command", .asked, "system", "All bots line 1: Anything → Reviewer: Jarvis", "Unsafe, destructive, or unparseable operations always require user review."),
                                                  ("review", .denied, "reviewer:\(jarvis.id.uuidString)", "finished a coding job", "Jarvis: changes requested")] {
            coder.approvalAudit.append(ApprovalAuditEntry(approvalID: UUID(), timestamp: start, actionKind: kind, outcome: outcome, decidedBy: by, reason: reason, rule: rule))
        }

        var fields = BotEditorFields(bot: coder); fields.routing = coder.effectiveRouting; fields.reviewAfter = coder.reviewAfter
        let editor = Form { BotEditorAdvancedSection(bot: coder, fields: .constant(fields)) }.formStyle(.grouped)
        write(names[0], await png(AnyView(editor.frame(width: 640, height: 900).background(AppColor.panel)), store, NSSize(width: 640, height: 900)))
        write(names[1], await png(AnyView(Form { SettingsApprovalsPane() }.formStyle(.grouped).frame(width: 760, height: 620).background(AppColor.panel)), store, NSSize(width: 760, height: 620)))
        store.selectedBot = coder
        let decidedRows = VStack(alignment: .leading, spacing: 0) {
            MessageView(message: coder.messages[0]); MessageView(message: decided)
            ApprovalCard(request: store.approvals[0]) { _ in }
            Spacer()
        }.padding(.top, 10)
        write(names[2], await png(AnyView(decidedRows.frame(width: 820, height: 420, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 420)))
        let reviewRows = VStack(alignment: .leading, spacing: 0) { MessageView(message: reply); MessageView(message: review); Spacer() }.padding(.top, 10)
        write(names[3], await png(AnyView(reviewRows.frame(width: 820, height: 560, alignment: .topLeading).background(AppColor.chat)), store, NSSize(width: 820, height: 560)))
        store.infoTab = .activity
        write(names[4], await png(AnyView(InfoPanel(bot: coder)), store, NSSize(width: 360, height: 760)))
    }
}
