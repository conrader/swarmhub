import Foundation

extension ChatMessage {
    func displayGoalResult(_ report: ChatGoal.Report, prose: String) {
        metadata[GoalKey.outcome] = report.outcome.rawValue
        metadata[GoalKey.evidence] = report.evidence
        content = prose.isEmpty ? report.evidence : prose
    }
}

extension Bot {
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
            var baseline = current
            baseline.detail = ""
            let expected = baseline.request(for: report.iteration)
            guard sent == expected || sent.hasPrefix(expected + "\nLast result: ") else { return }
        }
        current.interruptedAttempt = nil
        current.wait("Result recovered after SwarmHub closed. " + String(report.evidence.prefix(800)))
        if report.outcome == .complete { current.state = .completed }
        goal = current
    }
}
