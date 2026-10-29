import Foundation

/// P28 D4: `--e2e` step b as two checks. b1 steers a reply that is only writing (uxfix1: the answer is never stopped; the
/// steer lands in it, or the box hands it back and it goes as the next message); b2 steers while a tool step runs (the
/// steer lands after the step and the reply continues below it). Each passes only when the reply shows the effect; an
/// accepted steer the model never saw fails.
extension HeadlessE2E {
    static let steerToken = "E2E-STEER"
    static let steerCorrection = "Stop counting and reply with exactly: \(steerToken)"
    /// b2's one cheap action, slow enough to steer while it runs.
    static let toolPrompt = "Run exactly one shell command with your terminal tool: `sleep 15; echo E2E-TOOL`. Then count slowly from 1 to 10, one number per line"

    static func steerTextStep(store: AppStore, jarvis: Bot, timing: Timing) async -> Step {
        var step = Step(id: "b1", name: "steer during text", passed: false, detail: "")
        let bot = copy(jarvis, name: "\(jarvis.name) steer")
        store.bots.append(bot); select(bot, in: store)
        store.errorMessage = nil
        guard store.send(text: message("Count slowly from 1 to 20, one number per line")) else { step.detail = "not sent: \(store.errorMessage ?? "send refused")"; return step }
        let partial = store.turn(in: bot)?.assistant
        let tokens = await wait(timing.steerStart, poll: timing.poll) { store.isIdle(bot) || !(partial?.content.isEmpty ?? true) }
        guard tokens, !store.isIdle(bot) else {
            if !tokens { store.stop(bot) }
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | " + (tokens ? "turn ended before the first tokens could be steered" : "no tokens within \(timing.steerStart)") + (store.errorMessage.map { " (\($0))" } ?? "")
            return step
        }
        // uxfix1: without steer a send would only wait for the turn; this step checks steering itself.
        guard store.canSteer(in: bot), store.send(text: message(steerCorrection)) else {
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | steer not offered (run_steer=\(store.canSteer(in: bot)))"; return step
        }
        await finish(store, timing: timing)
        // A steer the box handed back starts a follow-up turn; let it end too. uxfix1-e2e: so does one whose request was
        // answered only after the turn ended, so wait for that answer first.
        // uxfix3: a steer the box refused (the run was finishing) waits as the next message ("next") and then goes.
        _ = await wait(timing.request, poll: timing.poll) { !bot.messages.contains { ["sent", "next"].contains($0.metadata[SteerKey.steer] ?? "") } }
        await finish(store, timing: timing)
        let outcome = steerTextOutcome(messages: bot.messages, partial: partial)
        step.passed = outcome.passed; step.detail = "session \(bot.hermesSessionID ?? "-") | \(outcome.detail)"
        return step
    }

    static func steerToolStep(store: AppStore, jarvis: Bot, timing: Timing) async -> Step {
        var step = Step(id: "b2", name: "steer during a tool step", passed: false, detail: "")
        let bot = copy(jarvis, name: "\(jarvis.name) steer tool")
        store.bots.append(bot); select(bot, in: store)
        store.errorMessage = nil
        guard store.send(text: message(toolPrompt)) else { step.detail = "not sent: \(store.errorMessage ?? "send refused")"; return step }
        let reply = store.turn(in: bot)?.assistant
        let running = await wait(timing.steerStart, poll: timing.poll) { store.isIdle(bot) || store.turn(in: bot)?.assistant?.activity?.current != nil }
        guard running, !store.isIdle(bot), let tool = store.turn(in: bot)?.assistant?.activity?.current?.name else {
            if !running { store.stop(bot) }
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | " + (running ? "no tool step ran (\(snippet(oneLine(reply?.content ?? ""))))" : "no tool step within \(timing.steerStart)")
            return step
        }
        guard store.canSteer(in: bot), store.send(text: message("After that step, reply with exactly: \(steerToken)")) else {
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | steer not offered (run_steer=\(store.canSteer(in: bot)))"; return step
        }
        await finish(store, timing: timing)
        // A steer the box handed back starts a follow-up turn; let it end too. uxfix1-e2e: so does one whose request was
        // answered only after the turn ended, so wait for that answer first.
        _ = await wait(timing.request, poll: timing.poll) { !bot.messages.contains { $0.metadata[SteerKey.steer] == "sent" } }
        await finish(store, timing: timing)
        let outcome = steerToolOutcome(messages: bot.messages, tool: tool)
        step.passed = outcome.passed; step.detail = "session \(bot.hermesSessionID ?? "-") | \(outcome.detail)"
        return step
    }

    /// b1 verdict: the answer was not stopped, and the reply after the steer bubble (its continuation or the follow-up) obeys.
    static func steerTextOutcome(messages: [ChatMessage], partial: ChatMessage?) -> (passed: Bool, detail: String) {
        guard let bubbleIndex = messages.lastIndex(where: { $0.isCorrection || $0.isSteer }) else { return (false, "no steer bubble") }
        let bubble = messages[bubbleIndex]
        let after = messages[(bubbleIndex + 1)...].first { $0.role == .assistant && !$0.content.isEmpty }
        let final = oneLine(after?.content ?? "")
        guard bubble.metadata[SteerKey.correction] != "stopped", partial?.turnState != .stopped else {
            return (false, "the answer was stopped (bubble: \(SteerCopy.caption(bubble) ?? "?"))")
        }
        guard let partial, !partial.content.isEmpty else { return (false, "no reply before the steer") }
        let kept = "answer not stopped (\(partial.content.count) chars) | steer \(SteerCopy.caption(bubble) ?? "?")"
        guard final.contains(steerToken) else { return (false, "\(kept) | accepted but ignored, reply: \(snippet(final))") }
        return (true, "\(kept) | reply: \(snippet(final))")
    }

    /// b2 verdict: the steer was delivered after the step and the reply part below the bubble obeys.
    static func steerToolOutcome(messages: [ChatMessage], tool: String) -> (passed: Bool, detail: String) {
        guard let bubbleIndex = messages.lastIndex(where: { $0.isCorrection || $0.isSteer }) else { return (false, "no steer bubble") }
        let bubble = messages[bubbleIndex]
        let after = messages[(bubbleIndex + 1)...].first { $0.role == .assistant && !$0.content.isEmpty }
        let final = oneLine(after?.content ?? "")
        let state = bubble.metadata[SteerKey.steer] ?? bubble.metadata[SteerKey.correction] ?? "?"
        switch state {
        case "delivered":
            guard after?.metadata[TurnKey.part] != nil else { return (false, "delivered, but no reply part below the steer") }
            guard final.contains(steerToken) else { return (false, "delivered after \(tool) but ignored, reply: \(snippet(final))") }
            return (true, "steer landed after the \(tool) step | reply below it: \(snippet(final))")
        case "followup": return (false, "the box handed the steer back after \(tool); answered as the next message: \(snippet(final))")
        case "stopped": return (false, "the answer was stopped instead (no step was running)")
        default: return (false, "steer \(state), never delivered (accepted but ignored)" + (final.isEmpty ? "" : ", reply: \(snippet(final))"))
        }
    }
}
