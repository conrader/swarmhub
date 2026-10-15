import Foundation

/// P45 5: `/heartbeat every <interval> [HH:MM–HH:MM] [<prompt>]` — unlike a box routine (its own cron session without the
/// chat's context), a heartbeat re-enters this chat's own conversation, on schedule, only while the chat is idle and inside
/// its window. "Woken by: heartbeat"; a reply that is exactly `[SILENT]` is hidden with its prompt (no preview, no alert).
extension AppStore {
    func heartbeat(in conversation: any Conversation) -> HeartbeatRun? { automations[conversation.id]?.heartbeat }

    func updateHeartbeat(in conversation: any Conversation, _ change: (inout HeartbeatRun) -> Void) {
        guard var heartbeat = automations[conversation.id]?.heartbeat else { return }
        change(&heartbeat); automations[conversation.id, default: .init()].heartbeat = heartbeat; save()
    }

    func heartbeatCommand(_ arguments: String, conversation: any Conversation) {
        switch arguments.lowercased() {
        case "", "status": commandLine(heartbeat(in: conversation).map(heartbeatStatus) ?? "No heartbeat in this chat. Type /heartbeat every 1h 08:00–23:00.", in: conversation)
        case "pause":
            guard heartbeat(in: conversation)?.paused == false else { commandLine("No running heartbeat to pause.", in: conversation); return }
            updateHeartbeat(in: conversation) { $0.paused = true }; commandLine("Heartbeat paused.", in: conversation)
        case "resume":
            guard heartbeat(in: conversation)?.paused == true else { commandLine("No paused heartbeat to resume.", in: conversation); return }
            updateHeartbeat(in: conversation) { $0.paused = false; $0.nextAt = max($0.nextAt, now()) }; commandLine("Heartbeat resumed.", in: conversation)
        case "stop":
            guard heartbeat(in: conversation) != nil else { commandLine("No heartbeat in this chat.", in: conversation); return }
            automations[conversation.id]?.heartbeat = nil; pruneAutomations(conversation); commandLine("Heartbeat stopped.", in: conversation)
        default:
            switch HeartbeatRun.parse(arguments, now: now()) {
            case .failure: commandLine("Say how often: /heartbeat every 1h [08:00–23:00] [<prompt>].", in: conversation)
            case .success(let run):
                let replaced = heartbeat(in: conversation) != nil
                automations[conversation.id, default: .init()].heartbeat = run; save(); startAutomationTicker()
                commandLine("\(replaced ? "Heartbeat replaced" : "Heartbeat started"): \(run.label). It checks in on this conversation while SwarmHub is open and the chat is idle; a [SILENT] answer stays hidden.", in: conversation)
            }
        }
    }

    func heartbeatStatus(_ heartbeat: HeartbeatRun) -> String {
        let minutes = max(0, Int(heartbeat.nextAt.timeIntervalSince(now()) / 60))
        return "\(heartbeat.label)\(heartbeat.paused ? " · paused" : "") · \(heartbeat.runs) check-ins · next in \(minutes) min\nPrompt: \(heartbeat.prompt)"
    }

    /// Idle means no reply running or waiting, and no goal or loop round on its way.
    func heartbeatCanRun(in conversation: any Conversation) -> Bool {
        let automation = automations[conversation.id]
        return isIdle(conversation) && !hasWaitingTurn(in: conversation) && !turns.pathDown && turnCapacityProblem(for: owner(of: conversation).map { [$0] } ?? []) == nil
            && automation?.goal?.state != .running && automation?.loop?.awaitingReply != true
    }

    func runHeartbeatIfDue(in conversation: any Conversation, bot: Bot) {
        guard let heartbeat = heartbeat(in: conversation), !heartbeat.paused, !heartbeat.awaitingReply, now() >= heartbeat.nextAt else { return }
        // Outside the window the beat is skipped, not saved up.
        guard heartbeat.inWindow(now()) else { updateHeartbeat(in: conversation) { $0.nextAt = now().addingTimeInterval($0.interval) }; return }
        guard heartbeatCanRun(in: conversation) else { return }
        let metadata = [AutomationKey.woken: AutomationKind.heartbeat.rawValue, AutomationKey.display: "Heartbeat"]
        guard send(text: heartbeat.prompt, bot: bot, conversation: conversation, replyToID: nil, waitWhenFull: false, metadata: metadata) else { return }
        updateHeartbeat(in: conversation) { $0.runs += 1; $0.awaitingReply = true; $0.nextAt = now().addingTimeInterval($0.interval) }
    }

    /// A heartbeat's reply that is exactly `[SILENT]`: it and its prompt are hidden.
    func heartbeatTurnEnded(in conversation: any Conversation, reply: ChatMessage, outcome: TurnOutcome) {
        guard heartbeat(in: conversation)?.awaitingReply == true else { return }
        updateHeartbeat(in: conversation) { $0.awaitingReply = false }
        guard isSilentHeartbeatReply(reply, in: conversation) else { return }
        reply.metadata[AutomationKey.silent] = "1"
        heartbeatPrompt(of: reply, in: conversation)?.metadata[AutomationKey.silent] = "1"
        objectWillChange.send(); save()
    }

    /// The reply answers a heartbeat prompt and says only `[SILENT]` (any case).
    func isSilentHeartbeatReply(_ reply: ChatMessage, in conversation: any Conversation) -> Bool {
        heartbeatPrompt(of: reply, in: conversation) != nil && HeartbeatRun.isSilent(SwarmhubBlock.visibleText(reply.finalText))
    }

    private func heartbeatPrompt(of reply: ChatMessage, in conversation: any Conversation) -> ChatMessage? {
        guard let index = conversation.messages.firstIndex(where: { $0.id == reply.id }) else { return nil }
        return conversation.messages[..<index].last { $0.role == .user && !$0.isSteer }.flatMap { $0.metadata[AutomationKey.woken] == AutomationKind.heartbeat.rawValue ? $0 : nil }
    }
}

extension ChatMessage {
    /// P45 5: a heartbeat prompt or reply hidden because the answer was `[SILENT]`.
    var isSilentHeartbeat: Bool { metadata[AutomationKey.silent] != nil }
}
