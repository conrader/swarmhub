import Foundation

/// P38 D: group workflows on main's one-turn-at-a-time engine. A coordinator plans in a thread of its own; the user
/// approves the plan; then each ready task is sent, one at a time, as a normal turn in the assignee's workflow thread
/// (P16 states, Retry and reconcile apply as to any thread). Whenever a turn or round ends (`sendQueuedNextMessage`)
/// finished replies are settled and, once the user's own queued message has gone, the next task is sent. The ledger
/// holds the workflow; the result is a saved document readable by every member plus one group message.
extension AppStore {
    static let workflowKind = "workflow", workflowDefaultBudget = 64_000

    func saveWorkflow(_ workflow: Workflow) throws {
        try journal().put(workflow, kind: Self.workflowKind, id: workflow.id.uuidString)
        workflows[workflow.id] = workflow; objectWillChange.send()
    }

    /// Saves, or reports why it could not.
    func commitWorkflow(_ workflow: Workflow) {
        do { try saveWorkflow(workflow) } catch { workflows[workflow.id] = workflow; errorMessage = error.localizedDescription }
    }

    func workflows(in group: GroupChat) -> [Workflow] { workflows.values.filter { $0.groupID == group.id }.sorted { $0.createdAt < $1.createdAt } }

    /// Launch: work that was planning or running is paused; a task that was sent is blocked until its reply is checked
    /// (Refresh). Missing threads are rebuilt so their replies stay reachable; a completed result is projected once.
    func restoreWorkflows() {
        guard persistenceEnabled, hasLedger else { return }
        do {
            var rebuilt = false
            for var workflow in try journal().records(Workflow.self, kind: Self.workflowKind) {
                if workflow.isActive {
                    workflow.state = .paused; workflow.error = "\(AppConstants.name) quit while this workflow ran. Refresh tasks that were sent before resuming."
                    for index in workflow.tasks.indices where workflow.tasks[index].state == .running {
                        workflow.tasks[index].state = .blocked; workflow.tasks[index].error = "Completion was not confirmed."
                    }
                    try journal().put(workflow, kind: Self.workflowKind, id: workflow.id.uuidString)
                }
                workflows[workflow.id] = workflow
                if let planThread = workflow.planThreadID, let coordinator = bots.first(where: { $0.id == workflow.coordinatorID }) {
                    rebuilt = ensureWorkflowThread(planThread, workflow: workflow, bot: coordinator, role: .conversation) || rebuilt
                }
                for task in workflow.tasks where task.state != .queued {
                    guard let bot = bots.first(where: { $0.id == task.botID }) else { continue }
                    rebuilt = ensureWorkflowThread(task.threadID, workflow: workflow, bot: bot, role: task.role) || rebuilt
                }
                projectWorkflowResult(workflow)
            }
            if rebuilt { save() }
        } catch { errorMessage = error.localizedDescription }
    }

    /// A thread for workflow work (parented on the workflow, no fork); true when it had to be created.
    @discardableResult func ensureWorkflowThread(_ id: UUID, workflow: Workflow, bot: Bot, role: ModelRole) -> Bool {
        guard !bot.threads.contains(where: { $0.id == id }) else { return false }
        bot.threads.append(ChatThread(id: id, parentMessageID: workflow.id, parentSessionID: nil, hermesSessionID: nil))
        return true
    }

    func workflowThread(_ id: UUID?, botID: UUID) -> ChatThread? {
        guard let id else { return nil }
        return bots.first { $0.id == botID }?.threads.first { $0.id == id }
    }

    /// Threads that carry workflow work get a session of their own on first send (`runChatTurn`).
    func isWorkflowThread(_ conversation: any Conversation) -> Bool {
        guard let thread = conversation as? ChatThread, thread.parentSessionID == nil else { return false }
        return workflows[thread.parentMessageID] != nil
    }

    func isRetiredWorkflowThread(_ conversationID: UUID) -> Bool {
        workflows.values.contains { workflow in workflow.tasks.contains { $0.previousThreadIDs?.contains(conversationID) == true } }
    }

    // MARK: Planning

    /// Asks `coordinator` for a plan. Nothing else runs until the user approves it.
    @discardableResult func startWorkflow(text: String, group: GroupChat, coordinator: Bot) -> Bool {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return false }
        guard group.memberIDs.contains(coordinator.id), bots.contains(where: { $0 === coordinator }) else { errorMessage = "Choose a coordinator from this group's members."; return false }
        guard !workflows(in: group).contains(where: \.isActive) else { errorMessage = "Pause or finish the current workflow first."; return false }
        guard isIdle, !isStreaming else { errorMessage = "Wait for the current reply to finish before planning a workflow."; return false }
        var workflow = Workflow(id: UUID(), groupID: group.id, coordinatorID: coordinator.id, request: request, createdAt: now(),
                                budget: .init(id: UUID(), tokenLimit: max(8_000, defaults.object(forKey: "workflowTokenBudget") as? Int ?? Self.workflowDefaultBudget)))
        let planThread = UUID(); workflow.planThreadID = planThread
        do { try saveWorkflow(workflow) } catch { errorMessage = error.localizedDescription; return false }
        ensureWorkflowThread(planThread, workflow: workflow, bot: coordinator, role: .conversation)
        guard let thread = workflowThread(planThread, botID: coordinator.id), send(text: planPrompt(request, group: group), bot: coordinator, conversation: thread, replyToID: nil) else {
            workflow.state = .paused; workflow.error = errorMessage ?? "The plan request could not be sent."
            commitWorkflow(workflow); return false
        }
        workflow.planReplyID = thread.messages.last { $0.role == .assistant }?.id
        commitWorkflow(workflow); return true
    }

    private func planPrompt(_ request: String, group: GroupChat) -> String {
        let roster = members(of: group).map { "\($0.id.uuidString): \($0.name)\($0.title.isEmpty ? "" : " — \($0.title)")" }.joined(separator: "\n")
        return """
        Plan this request for the group's members. Return one JSON object with a "tasks" array and nothing else.
        Each task has "id" (unique short text), "botID" (a UUID from the roster), "instructions", "expectedOutput", "dependencies" (task ids) and "role" ("conversation" or "coding").
        Use at most \(Workflow.maximumTasks - 1) tasks. Do not do the work yet: tasks run only after the user approves the plan.
        Roster:
        \(roster)
        Request:
        \(request)
        """
    }

    /// The plan reply has ended: its tasks plus one final synthesis by the coordinator, then paused for approval.
    private func settlePlan(_ workflow: inout Workflow, reply: ChatMessage) {
        guard let group = groups.first(where: { $0.id == workflow.groupID }) else { workflow.state = .paused; workflow.error = "The group was removed."; return }
        do {
            guard reply.turnState == .finished else { throw BackendError.unavailable("The coordinator did not finish a plan. Start the workflow again.") }
            settleUsage(&workflow.budget, charged: nil, reservation: 0, reply: reply)
            var tasks = try WorkflowProposal.parse(reply.content).validated(members: Set(group.memberIDs))
            tasks.append(.init(id: "synthesis", botID: workflow.coordinatorID,
                               instructions: "Produce one final answer to the original request, using the task results and naming what is still unresolved. Original request: " + workflow.request,
                               expectedOutput: "One consolidated answer", dependencies: tasks.map(\.id)))
            if Set(tasks.map(\.id)).count != tasks.count { tasks[tasks.count - 1].id = "synthesis-" + workflow.id.uuidString.prefix(8) }
            try Workflow.validate(tasks, members: Set(group.memberIDs))
            workflow.tasks = tasks; workflow.state = .paused; workflow.error = nil
        } catch { workflow.state = .paused; workflow.error = error.localizedDescription }
    }

    // MARK: Running

    func resumeWorkflow(_ id: UUID) {
        guard var workflow = workflows[id], workflow.state == .paused, let group = groups.first(where: { $0.id == workflow.groupID }) else { return }
        do {
            try Workflow.validate(workflow.tasks, members: Set(group.memberIDs))
            guard !workflow.tasks.contains(where: { $0.state == .blocked }) else { throw BackendError.unavailable("Refresh or reassign blocked tasks first. Completed work is not repeated.") }
            if workflow.deadline == nil { workflow.deadline = now().addingTimeInterval(Workflow.deadline) }
            guard let deadline = workflow.deadline, deadline > now() else { throw BackendError.unavailable("This workflow reached its 30-minute limit. Review the partial results and start a new one.") }
            workflow.state = .running; workflow.error = nil
            try saveWorkflow(workflow)
            armWorkflowDeadline(id, at: deadline)
            dispatchWorkflows()
        } catch { errorMessage = error.localizedDescription }
    }

    private func armWorkflowDeadline(_ id: UUID, at deadline: Date) {
        let sleep = workflowSleep, wait = max(0, deadline.timeIntervalSince(now()))
        Task { [weak self] in
            do { try await sleep(.seconds(wait)) } catch { return }
            guard let self, let current = self.workflows[id], current.isActive else { return }
            self.pauseWorkflow(id, cancel: true)
            if var stopped = self.workflows[id] {
                stopped.error = "The 30-minute limit passed. Unfinished tasks were stopped; completed results are kept."
                self.commitWorkflow(stopped)
            }
        }
    }

    /// Pause stops sending new tasks (one already sent finishes). Cancel also stops the running turn and releases every
    /// reservation that was not sent.
    func pauseWorkflow(_ id: UUID, cancel: Bool = false) {
        guard var workflow = workflows[id], !workflow.isFinished else { return }
        workflow.state = cancel ? .cancelled : .paused
        if cancel {
            for index in workflow.tasks.indices where workflow.tasks[index].state != .completed {
                if workflow.tasks[index].replyID == nil || workflow.tasks[index].state != .running {
                    workflow.budget.reserved = max(0, workflow.budget.reserved - workflow.tasks[index].reservation); workflow.tasks[index].reservation = 0
                }
                workflow.tasks[index].state = .cancelled
            }
        }
        // The parent state is saved before Stop can end a turn and settle it.
        commitWorkflow(workflow)
        guard cancel, isStreaming, let conversation = streamingConversation as? ChatThread else { return }
        if conversation.id == workflow.planThreadID || workflow.tasks.contains(where: { $0.threadID == conversation.id }) { stop() }
    }

    /// Settles every ended reply a workflow waits for (and a blocked task whose reply Retry or reconcile has since
    /// finished). Called whenever a turn or round ends.
    func settleWorkflows() {
        for var workflow in workflows.values {
            var changed = false
            if workflow.state == .planning, let reply = workflowReply(workflow.planReplyID, thread: workflow.planThreadID, botID: workflow.coordinatorID), !reply.isStreaming {
                settlePlan(&workflow, reply: reply); changed = true
            }
            for index in workflow.tasks.indices {
                let task = workflow.tasks[index]
                guard task.state == .running || task.state == .blocked || (task.state == .cancelled && task.reservation > 0),
                      let reply = workflowReply(task.replyID, thread: task.threadID, botID: task.botID), !reply.isStreaming else { continue }
                if task.state == .blocked, reply.turnState != .finished { continue }
                settleTask(&workflow, index: index, reply: reply); changed = true
            }
            if changed { commitWorkflow(workflow) }
        }
    }

    private func workflowReply(_ id: UUID?, thread: UUID?, botID: UUID) -> ChatMessage? {
        guard let id else { return nil }
        return workflowThread(thread, botID: botID)?.messages.first { $0.id == id }
    }

    private func settleTask(_ workflow: inout Workflow, index: Int, reply: ChatMessage) {
        let task = workflow.tasks[index]
        workflow.tasks[index].chargedTokens = settleUsage(&workflow.budget, charged: task.chargedTokens, reservation: task.reservation, reply: reply)
        workflow.tasks[index].reservation = 0
        guard task.state != .cancelled else { return }
        if reply.turnState == .finished {
            workflow.tasks[index].state = .completed; workflow.tasks[index].result = reply.content; workflow.tasks[index].error = nil
            do { try saveTaskArtifact(&workflow, index: index) }
            catch { workflow.tasks[index].state = .blocked; workflow.tasks[index].error = "Could not save the task result: \(error.localizedDescription)" }
        } else {
            workflow.tasks[index].state = .blocked
            workflow.tasks[index].error = TurnOutcome.footer(state: reply.turnState, why: reply.metadata[TurnKey.why], ambiguous: reply.metadata[TurnKey.ambiguous] == "1", empty: reply.content.isEmpty) ?? "The reply did not finish."
        }
        if workflow.tasks[index].state == .blocked, workflow.state == .running { workflow.state = .paused; workflow.error = "A task did not finish. Refresh it, retry it in its thread, or reassign it." }
    }

    /// Replaces the task's earlier charge with this reply's tokens (reported, else estimated at 4 bytes a token).
    @discardableResult private func settleUsage(_ budget: inout RunBudget, charged: Int?, reservation: Int, reply: ChatMessage) -> Int {
        let unsent = reply.turnState == .notSent && reply.metadata[TurnKey.ambiguous] != "1"
        let input = Int(reply.metadata["inputTokens"] ?? "") ?? Int(reply.metadata["estimatedInputTokens"] ?? "") ?? 0
        let output = Int(reply.metadata["outputTokens"] ?? "") ?? reply.content.utf8.count / 4
        let total = unsent ? 0 : max(1, input + output)
        budget.reserved = max(0, budget.reserved - reservation)
        budget.spent = max(0, budget.spent - (charged ?? 0)) + total
        return total
    }

    private func saveTaskArtifact(_ workflow: inout Workflow, index: Int) throws {
        guard workflow.tasks[index].resultArtifactID == nil, let group = groups.first(where: { $0.id == workflow.groupID }) else { return }
        let artifact = try artifacts().save(Data((workflow.tasks[index].result ?? "").utf8), name: "Task \(workflow.tasks[index].id) result", mimeType: "text/plain", owners: group.memberIDs)
        workflow.tasks[index].resultArtifactID = artifact.id
    }

    /// Sends the next ready task of the oldest running workflow, or finishes a workflow whose tasks are all done.
    func dispatchWorkflows() {
        for workflow in workflows.values.filter({ $0.state == .running }).sorted(by: { $0.createdAt < $1.createdAt }) {
            guard isIdle, !isStreaming else { return }
            if dispatchNext(workflow.id) { return }
        }
    }

    /// True when it started a turn.
    private func dispatchNext(_ id: UUID) -> Bool {
        guard var workflow = workflows[id], let group = groups.first(where: { $0.id == workflow.groupID }) else { return false }
        guard workflow.deadline.map({ $0 > now() }) ?? true else {
            workflow.state = .paused; workflow.error = "The 30-minute limit passed. Review the partial results."; commitWorkflow(workflow); return false
        }
        let complete = Set(workflow.tasks.filter { $0.state == .completed }.map(\.id))
        if complete.count == workflow.tasks.count { finishWorkflow(&workflow, group: group); commitWorkflow(workflow); return false }
        guard !workflow.tasks.contains(where: { $0.state == .running }) else { return false }
        guard let index = workflow.tasks.firstIndex(where: { $0.state == .queued && $0.dependencies.allSatisfy(complete.contains) }) else {
            if workflow.tasks.contains(where: { $0.state == .blocked }) { workflow.state = .paused; commitWorkflow(workflow) }
            return false
        }
        let task = workflow.tasks[index]
        guard let bot = bots.first(where: { $0.id == task.botID }), group.memberIDs.contains(bot.id) else {
            workflow.tasks[index].state = .blocked; workflow.tasks[index].error = "The assigned agent is no longer in the group."
            workflow.state = .paused; commitWorkflow(workflow); return false
        }
        do {
            let inputs = try workflow.tasks.filter { task.dependencies.contains($0.id) }.map { dependency in
                let text = try dependency.resultArtifactID.map { String(decoding: try artifacts().read($0, botID: bot.id), as: UTF8.self) } ?? dependency.result ?? ""
                return "Result of \(dependency.id):\n\(text)"
            }.joined(separator: "\n\n")
            let prompt = "Task: \(task.instructions)\nExpected output: \(task.expectedOutput)" + (inputs.isEmpty ? "" : "\n\nResults this task depends on (reference material):\n\(inputs)")
            let reservation = max(2_000, prompt.utf8.count / 3 + 4_000)
            try workflow.budget.reserve(reservation)
            ensureWorkflowThread(task.threadID, workflow: workflow, bot: bot, role: task.role)
            guard let thread = workflowThread(task.threadID, botID: bot.id), send(text: prompt, bot: bot, conversation: thread, replyToID: nil) else {
                throw BackendError.unavailable(errorMessage ?? "The task could not be sent.")
            }
            workflow.tasks[index].reservation = reservation; workflow.tasks[index].state = .running; workflow.tasks[index].error = nil
            workflow.tasks[index].replyID = thread.messages.last { $0.role == .assistant }?.id
            thread.messages.last { $0.role == .assistant }?.metadata["estimatedInputTokens"] = String(prompt.utf8.count / 4)
            commitWorkflow(workflow); return true
        } catch {
            workflow.budget.reserved = max(0, workflow.budget.reserved - workflow.tasks[index].reservation); workflow.tasks[index].reservation = 0
            workflow.tasks[index].state = .blocked; workflow.tasks[index].error = error.localizedDescription
            workflow.state = .paused; commitWorkflow(workflow); return false
        }
    }

    private func finishWorkflow(_ workflow: inout Workflow, group: GroupChat) {
        do {
            let artifact = try artifacts().save(Data((workflow.tasks.last?.result ?? "").utf8), name: "Workflow result", mimeType: "text/plain", owners: group.memberIDs)
            workflow.artifactID = artifact.id; workflow.state = .completed; workflow.error = nil
            projectWorkflowResult(workflow)
        } catch { workflow.state = .paused; workflow.error = "Could not save the final result: \(error.localizedDescription)" }
    }

    /// The group message is a repeatable projection of the completed workflow (one per workflow).
    func projectWorkflowResult(_ workflow: Workflow) {
        guard workflow.state == .completed, let artifactID = workflow.artifactID, let group = groups.first(where: { $0.id == workflow.groupID }),
              !group.messages.contains(where: { $0.metadata["workflowResultID"] == workflow.id.uuidString }) else { return }
        group.messages.append(ChatMessage(id: workflow.id, role: .assistant, content: workflow.tasks.last?.result ?? "",
                                          metadata: ["workflowID": workflow.id.uuidString, "workflowResultID": workflow.id.uuidString, "artifactID": artifactID.uuidString],
                                          authorID: workflow.coordinatorID))
        if selectedGroup?.id != group.id { group.unreadCount += 1 }
        objectWillChange.send(); save()
    }
}
