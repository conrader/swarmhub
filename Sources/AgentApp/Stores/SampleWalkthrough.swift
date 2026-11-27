import Foundation

enum SampleWalkthrough: String, Codable, CaseIterable {
    case release, checks, brief, team

    enum Step: Int, Codable {
        case opening = 1, handoff, result
    }

    struct Position: Codable, Equatable {
        let run: UUID
        let story: SampleWalkthrough
        var step: Step
    }

    var owner: SampleWorkspace.Role {
        switch self {
        case .release, .checks: .patch
        case .brief: .scout
        case .team: .jarvis
        }
    }

    var title: String {
        switch self {
        case .release: "Release notes"
        case .checks: "CI & reviewer bot"
        case .brief: "Routines & brief"
        case .team: "Team & helpers"
        }
    }

    func button(at step: Step) -> String {
        switch (self, step) {
        case (_, .result): "Replay walkthrough"
        case (.release, .opening): "Hand off to Scout"
        case (.release, .handoff): "Read Patch’s draft"
        case (.checks, .opening): "Review the failing check"
        case (.checks, .handoff): "Review the test command"
        case (.brief, .opening): "Gather server status"
        case (.brief, .handoff): "Read the morning brief"
        case (.team, .opening): "Review the new roles"
        case (.team, .handoff): "Open the Payments proposal"
        }
    }

    static let briefTitle = "Morning brief"
    static let draftMarker = "sample.release.draft"

    static func draft(short: Bool) -> ChatMessage {
        let notes = short
            ? "- Paste screenshots into bot chats.\n- Review approvals in one inbox.\n- Schedule routines with a spending limit."
            : "- Paste screenshots into Claude Code, Codex, Gemini CLI or OpenCode chats.\n- Review pending commands and bot proposals in Needs Attention.\n- Schedule recurring routines and keep goal runs within their spending limits."
        let page = PageDraft(title: "Release notes", markdown: notes)
        guard let data = try? JSONEncoder().encode(page) else { return .init(role: .assistant, content: notes) }
        return ChatMessage(role: .assistant, content: "Here is the release note draft for your review.\n\n```page-draft\n" + String(decoding: data, as: UTF8.self) + "\n```",
                           metadata: [draftMarker: short ? "short" : "full"])
    }

    /// Recorded tool events use the same expandable activity row as a live turn.
    private static func reply(_ text: String, tools: [(String, String)] = [], seconds: Int = 0) -> ChatMessage {
        let row = ChatMessage(role: .assistant, content: text)
        guard !tools.isEmpty else { return row }
        var activity = ToolActivity()
        let end = row.createdAt, duration = Double(seconds) / Double(tools.count)
        for (index, tool) in tools.enumerated() {
            let start = end.addingTimeInterval(-Double(seconds) + duration * Double(index))
            activity.apply(.init(phase: .started, name: tool.0, preview: tool.1, callID: String(index)), at: start)
            activity.apply(.init(phase: .completed, name: tool.0, callID: String(index)), at: start.addingTimeInterval(duration))
        }
        activity.finish(at: end)
        row.activity = activity
        return row
    }

    func opening() -> [ChatMessage] {
        switch self {
        case .release:
            [.init(role: .user, content: "Patch, turn the three changes in this build into release notes."),
             Self.reply("I’ll check the commits and ask Scout to verify the user-facing changes before I draft the notes.",
                        tools: [("bash", "git log v0.8.15..HEAD --oneline"), ("send_message", "@Scout verify user-facing changes")], seconds: 6)]
        case .checks:
            [.init(role: .user, content: "Patch, watch PR #142 and inspect any failing check."),
             Self.reply("I’m watching PR #142. A failed check wakes me up so I can investigate.",
                        tools: [("watch", "conrader/swarmhub#142")], seconds: 2)]
        case .brief:
            [.init(role: .system, content: "Morning brief · Weekdays at 08:55"),
             Self.reply("I’m checking the sample servers, overnight helper runs and outstanding decisions.")]
        case .team:
            [.init(role: .system, content: "Patch asked Jarvis for Legal and Payments."),
             Self.reply("Legal handles read-only contract reviews using OpenCode and DeepSeek with a $2.00 session cap.")]
        }
    }

    func handoff(for bot: Bot, teammate: Bot?) -> [ChatMessage] {
        let request: String, response: ChatMessage
        switch self {
        case .release:
            request = "Verify the three changes for the release notes."
            response = Self.reply("I verified the unified Inbox, screenshot input and scheduled routines against the changelog and tests.",
                                  tools: [("read", "docs/CHANGELOG.md"), ("read", "docs/FEATURES.md"), ("bash", "swift test --filter ReleaseNotesTests")], seconds: 11)
        case .checks:
            request = "Review the fix and the command for PR #142."
            response = Self.reply("I reviewed the CSV reader change. The importer test runs inside /srv/shop and only reads the project.",
                                  tools: [("read", "macos-14 / swift-test"), ("review", "swift test --filter ImporterTests")], seconds: 14)
        case .brief:
            request = "Report the status of your helpers for the morning brief."
            response = Self.reply("The rename finished in 41 seconds. Three skill updates are ready to sync.")
        case .team:
            return [Self.reply(bot.sampleDecision?.receipt ?? "Legal is on the team. The Payments proposal is in Needs Attention because the role handles invoices.")]
        }
        guard let teammate else { return [Self.reply("The teammate for this step is no longer in the sample workspace.")] }
        teammate.messages.append(AppOnlyLine.line(HerdrMessageLine.sent.render(bot.name, teammate.name, request)))
        teammate.messages.append(.init(role: .assistant, content: response.content))
        response.authorID = teammate.id
        return [AppOnlyLine.line(HerdrMessageLine.sent.render(bot.name, teammate.name, request)), response]
    }

    func result(for bot: Bot, pending: Int, testsRunning: Bool) -> ChatMessage {
        switch self {
        case .release: return Self.draft(short: false)
        case .checks, .team:
            return Self.reply(bot.sampleDecision?.receipt ?? (self == .team ? "Review the Payments proposal here or in Needs Attention." : "Scout has reviewed the importer tests. You can now decide whether Patch runs them."))
        case .brief:
            let body = "The sample build passed verification.\n\nThe rename finished in 41 seconds. The tests helper is " + (testsRunning ? "working." : "stopped.") + "\n\nNeeds Attention has \(pending) pending \(pending == 1 ? "item" : "items")."
            let row = Self.reply("I saved the morning brief in the sample workspace’s Pages.")
            let page = HerdrClient.RoutinePage(id: 1, revision: bot.messages.compactMap { $0.publishedResults?.items.first?.revision }.max().map { $0 + 1 } ?? 1,
                                               title: Self.briefTitle, excerpt: body)
            row.publishedResults = .init(serverID: SampleWorkspace.server.id, items: [.init(page: page, journalID: page.revision)])
            return row
        }
    }
}

extension AppStore {
    var sampleBriefs: [HerdrPublishedResult] {
        bots.filter { $0.sampleProfile != nil && $0.sampleRole == .scout && !$0.isHidden }
            .flatMap { $0.messages }.compactMap(\.publishedResults)
            .filter { $0.serverID == SampleWorkspace.server.id }.flatMap(\.items)
            .filter { $0.kind == .page }.sorted { ($0.revision ?? 0) > ($1.revision ?? 0) }
    }

    func showSampleStory(_ story: SampleWalkthrough) {
        guard let owner = bots.first(where: { !$0.isHidden && $0.sampleProfile != nil && $0.sampleRole == story.owner }) else { return }
        open(owner)
        if owner.sampleWalkthrough?.story != story { beginSampleStory(story, in: owner) }
    }

    func beginSampleStory(_ story: SampleWalkthrough, in bot: Bot) {
        guard bot.sampleProfile != nil, bot.sampleRole == story.owner else { return }
        bot.sampleWalkthrough = .init(run: UUID(), story: story, step: .opening)
        bot.messages.append(contentsOf: story.opening())
        chatScroll.toBottom(bot.id)
        save()
    }

    func advanceSampleStory(in bot: Bot, from position: SampleWalkthrough.Position) {
        let story = position.story
        guard bots.contains(bot), bot.sampleProfile != nil, bot.sampleRole == story.owner, bot.sampleWalkthrough == position else { return }
        switch position.step {
        case .opening:
            let role: SampleWorkspace.Role = story == .brief ? .jarvis : .scout
            let teammate = bots.first { $0.sampleProfile != nil && $0.sampleRole == role }
            bot.messages.append(contentsOf: story.handoff(for: bot, teammate: teammate))
            bot.sampleWalkthrough?.step = .handoff
        case .handoff:
            let pending = bots.filter { !$0.isHidden && $0.pendingSampleReview != nil }.count
            let running = bots.first(where: SampleWorkspace.isCoordinator).flatMap { herdrHelpers[$0.id]?.claudeThreads?.first?.isWorking } ?? false
            bot.messages.append(story.result(for: bot, pending: pending, testsRunning: running))
            bot.sampleWalkthrough?.step = .result
        case .result:
            beginSampleStory(story, in: bot)
            return
        }
        chatScroll.toBottom(bot.id)
        save()
    }
}
