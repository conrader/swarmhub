import Foundation

extension ChatMessage {
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
        if cleaned != current.objective { current.objective = cleaned; goal = current }
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
        let assessed = current.assessed(report)
        current.recordMeasurement(report.measurement)
        answer.metadata[GoalKey.outcome] = assessed.outcome.rawValue
        answer.metadata[GoalKey.evidence] = assessed.evidence
        current.interruptedAttempt = nil
        current.wait("Result recovered after SwarmHub closed. " + String(assessed.evidence.prefix(800)))
        if assessed.outcome == .complete { current.state = .completed }
        goal = current
    }
}
