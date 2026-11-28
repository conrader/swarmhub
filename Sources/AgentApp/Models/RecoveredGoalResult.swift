import Foundation

extension ChatMessage {
    /// The reply shows a card or a list of options that waits for the person's choice.
    var asksForAnswer: Bool {
        ChatCardParser.parseVisibleReply(content).contains {
            switch $0 {
            case .choices, .multiChoices, .draft, .pageDraft: true
            default: false
            }
        } || ChatChoiceInference.options(in: content) != nil
    }

    func displayGoalResult(_ report: ChatGoal.Report, prose: String) {
        metadata[GoalKey.outcome] = report.outcome.rawValue
        metadata[GoalKey.evidence] = report.evidence
        content = prose.isEmpty ? report.evidence : prose
    }
}

extension Bot {
    /// Older versions appended the entire answered card to the objective. Remove
    /// only an exact quoted acknowledgement that also exists in this chat.
    func retireSavedGoalApprovals() {
        guard var current = goal, current.state.active, current.objective.contains("\nFollow-up: In reply to “") else { return }
        let acknowledgements: Set<String> = ["yes", "tak", "ok", "okay"]
        var parts = current.objective.components(separatedBy: "\nFollow-up: ")
        let original = parts.removeFirst()
        let answered = Set(messages.compactMap { row -> String? in
            guard row.role == .user, let quote = row.metadata[ChoiceReply.quoteKey],
                  acknowledgements.contains(row.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            else { return nil }
            return "In reply to “" + quote + "”\n" + row.content
        })
        let cleaned = ([original] + parts.filter { !answered.contains($0) }).joined(separator: "\nFollow-up: ")
        if cleaned != current.objective {
            // Preserve the link to the dispatched step before normalizing its saved wording.
            if current.lastBeganAttempt == nil,
               let row = messages.last(where: { $0.role == .user && $0.metadata[GoalKey.attempt] != nil }),
               let token = row.metadata[GoalKey.attempt].flatMap(UUID.init(uuidString:)),
               let request = row.metadata[GoalKey.request], current.matchesSavedRequest(request, token: token) {
                current.lastBeganAttempt = token
            }
            current.objective = cleaned
            goal = current
        }
    }


    /// A workspace can save the final answer after the desktop stops listening. Correlate
    /// the explicit iteration token inside this conversation, even across team handoffs.
    func recoverGoalResult(in answer: ChatMessage) {
        guard answer.role == .assistant,
              answer.metadata[GoalKey.attempt] != nil || answer.metadata["herdrJournal"] != nil || answer.metadata["herdrTeamEntry"] != nil,
              answer.content.contains("\"iteration\""),
              let (report, prose) = ChatGoal.Report.read(answer.content) else { return }
        let token = report.iteration.uuidString
        guard let request = messages.last(where: { $0.role == .user && $0.metadata[GoalKey.attempt] == token }),
              let original = messages.first(where: {
                  $0.role == .assistant && $0.metadata[GoalKey.attempt] == token && $0.metadata[TurnKey.forUser] == request.id.uuidString
              }), answer === original || answer.metadata[GoalKey.attempt] == nil else { return }

        answer.displayGoalResult(report, prose: prose)
        answer.metadata[TurnKey.forUser] = request.id.uuidString
        if original.turnState == .incomplete {
            original.turnState = .finished
            original.deliveryReceipt = nil
            for key in [TurnKey.why, TurnKey.agent, TurnKey.ambiguous, TurnKey.reconnecting] { original.metadata[key] = nil }
            if var activity = original.activity, activity.endedAt == nil {
                activity.finish(at: max(activity.steps.last?.startedAt ?? original.createdAt, answer.createdAt))
                original.activity = activity
            }
        }
        guard var current = goal else { return }
        let interrupted = current.state == .waiting && current.detail == ChatGoal.interruptedDetail
        if current.state == .running {
            guard current.attempt == report.iteration else { return }
        } else if interrupted, let remembered = current.interruptedAttempt {
            guard remembered == report.iteration else { return }
        } else {
            // Older stores cleared the attempt at launch. Match the last dispatched request
            // and its full objective before updating the existing pause.
            guard interrupted, messages.last(where: { $0.role == .user && $0.metadata[GoalKey.attempt] != nil }) === request,
                  let sent = request.metadata[GoalKey.request] else { return }
            guard current.matchesSavedRequest(sent, token: report.iteration) else { return }
        }
        current.interruptedAttempt = nil
        if answer.asksForAnswer {
            // A question to the person is theirs to answer, whatever outcome the step reported.
            let assessed = current.assessed(report)
            current.recordMeasurement(report.measurement)
            answer.metadata[GoalKey.outcome] = ChatGoal.Report.Outcome.blocked.rawValue
            answer.metadata[GoalKey.evidence] = assessed.evidence
            current.wait("Result recovered after SwarmHub closed. Review the reply in this chat, then resume the goal.")
            goal = current
            return
        }
        // Settle the recovered step the way a step heard live is settled. Confirmed progress goes on to
        // the next step by itself; the goal stops here only when it is blocked, stalled, at a limit or done.
        current.state = .running
        current.attempt = report.iteration
        let settled = current.finish(report)
        answer.metadata[GoalKey.outcome] = settled.outcome.rawValue
        answer.metadata[GoalKey.evidence] = settled.evidence
        if current.state == .waiting {
            current.detail = "Result recovered after SwarmHub closed. " + String(settled.evidence.prefix(800))
        }
        goal = current
    }
}
