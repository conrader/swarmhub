import Foundation

/// P45 3: `/loop` — the prompt again on its interval while SwarmHub runs ("Woken by: loop"), ending after `--times N`, when
/// the bot reports the `--until` condition met, or on `/loop stop` / Stop. Box-side schedules are Routines. When SwarmHub
/// quits, a loop in a Bot Chat keeps running on the box until the next launch (`AppStore+AutomationHandoff.swift`).
extension AppStore {
    static let loopRoutinesHint = "It runs while SwarmHub is open; in the bot's main chat it also keeps running on the box while SwarmHub is closed. For a schedule that lives on the box, use the bot's Routines."

    func loop(in conversation: any Conversation) -> LoopRun? { automations[conversation.id]?.loop }

    func updateLoop(in conversation: any Conversation, _ change: (inout LoopRun) -> Void) {
        guard var loop = automations[conversation.id]?.loop else { return }
        change(&loop); automations[conversation.id, default: .init()].loop = loop; save()
    }

    func loopCommand(_ arguments: String, bot: Bot, conversation: any Conversation) {
        switch arguments.lowercased() {
        case "", "status": commandLine(loop(in: conversation).map { loopStatus($0) } ?? "No loop in this chat. Type /loop 10m <prompt>.", in: conversation)
        case "pause":
            guard loop(in: conversation)?.paused == false else { commandLine("No running loop to pause.", in: conversation); return }
            updateLoop(in: conversation) { $0.paused = true }; commandLine("Loop paused.", in: conversation)
        case "resume":
            guard loop(in: conversation)?.paused == true else { commandLine("No paused loop to resume.", in: conversation); return }
            updateLoop(in: conversation) { $0.paused = false; $0.nextAt = max($0.nextAt, now()) }; commandLine("Loop resumed.", in: conversation)
            runLoopIfDue(in: conversation, bot: bot)
        case "takeover" where automations[conversation.id]?.boxHandoff?.kind == .loop: takeOverHandoff(in: conversation)
        case "stop":
            guard loop(in: conversation) != nil else { commandLine("No loop in this chat.", in: conversation); return }
            endLoop(in: conversation, line: "Loop stopped.")
        default:
            switch LoopRun.parse(arguments, now: now()) {
            case .failure(.noPrompt): commandLine("Type what to send: /loop 10m <prompt> [--times N] [--until <condition>].", in: conversation)
            case .failure(.badTimes): commandLine("--times needs a number above 0.", in: conversation)
            case .success(let run):
                let replaced = loop(in: conversation) != nil
                automations[conversation.id, default: .init()].loop = run; save(); startAutomationTicker()
                commandLine("\(replaced ? "Loop replaced" : "Loop started"): \(run.label). \(Self.loopRoutinesHint)", in: conversation)
                runLoopIfDue(in: conversation, bot: bot)
            }
        }
    }

    func loopStatus(_ loop: LoopRun) -> String {
        let minutes = max(0, Int(loop.nextAt.timeIntervalSince(now()) / 60))
        return "\(loop.label)\(loop.paused ? " · paused" : "") · sent \(loop.runs) · next \(loop.awaitingReply ? "after this reply" : minutes == 0 ? "now" : "in \(minutes) min")\nPrompt: \(loop.prompt)"
    }

    /// Sends the prompt when it is due and the chat is free and online; a busy chat gets it as soon as it is idle.
    func runLoopIfDue(in conversation: any Conversation, bot: Bot) {
        guard let loop = loop(in: conversation), !loop.paused, !loop.awaitingReply, now() >= loop.nextAt,
              automations[conversation.id]?.boxHandoff?.kind != .loop,
              isIdle(conversation), !hasWaitingTurn(in: conversation), !turns.pathDown else { return }
        let metadata = [AutomationKey.woken: AutomationKind.loop.rawValue, AutomationKey.display: loop.prompt]
        guard send(text: loop.message, bot: bot, conversation: conversation, replyToID: nil, waitWhenFull: true, metadata: metadata) else { return }
        updateLoop(in: conversation) { run in
            run.runs += 1; run.awaitingReply = true; run.nextAt = now().addingTimeInterval(run.interval)
            if let left = run.timesLeft { run.timesLeft = left - 1 }
        }
    }

    /// The end of a loop turn: Stop ends the loop, the `--until` block or the last of `--times` ends it.
    func loopTurnEnded(in conversation: any Conversation, reply: ChatMessage, outcome: TurnOutcome) {
        guard let loop = loop(in: conversation), loop.awaitingReply else { return }
        updateLoop(in: conversation) { $0.awaitingReply = false }
        if outcome.state == .stopped { endLoop(in: conversation, line: "Loop stopped."); return }
        if let until = loop.until, outcome.state == .finished, LoopRun.loopDone(in: reply.finalText) { endLoop(in: conversation, line: "Loop ended: \(until)."); return }
        if loop.timesLeft == 0 { endLoop(in: conversation, line: "Loop finished after \(loop.runs) \(loop.runs == 1 ? "run" : "runs").") }
    }

    func endLoop(in conversation: any Conversation, line: String) {
        automations[conversation.id]?.loop = nil; pruneAutomations(conversation)
        commandLine(line, in: conversation)
    }
}
