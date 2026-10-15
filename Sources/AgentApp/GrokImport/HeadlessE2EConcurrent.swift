import Foundation

/// P39: `--e2e` step h. Two bots are asked at the same moment (fresh self-test copies of Jarvis and DMT); both turns run
/// at once, Stop on the first leaves the second's reply complete.
extension HeadlessE2E {
    static let concurrentToken = "E2E-CONCURRENT"

    static func concurrentStep(store: AppStore, bots: Participants, tag: String, timing: Timing) async -> Step {
        var step = Step(id: "h", name: "concurrent", passed: false, detail: "")
        let first = copy(bots.jarvis, name: "\(bots.jarvis.name) h \(tag)"), second = copy(bots.dmt, name: "\(bots.dmt.name) h \(tag)")
        store.bots.append(contentsOf: [first, second])
        defer { store.bots.removeAll { $0 === first || $0 === second } }
        store.errorMessage = nil
        select(first, in: store)
        guard store.send(text: message("Count slowly from 1 to 20, one number per line")) else { step.detail = "first not sent: \(store.errorMessage ?? "send refused")"; return step }
        select(second, in: store)
        guard store.send(text: message("Count from 1 to 5, one number per line, then reply with exactly: \(concurrentToken)")) else {
            store.stop(first); _ = await wait(timing.turn, poll: timing.poll) { store.isIdle(first) }
            step.detail = "second not sent while the first answered: \(store.errorMessage ?? "send refused")"; return step
        }
        let both = !store.isIdle(first) && !store.isIdle(second)
        let partial = store.turn(in: first)?.assistant
        let tokens = await wait(timing.steerStart, poll: timing.poll) { store.isIdle(first) || !(partial?.content.isEmpty ?? true) }
        let secondRunning = !store.isIdle(second)
        let stopped = tokens && !store.isIdle(first)
        store.stop(first)
        let ended = await wait(timing.turn, poll: timing.poll) { store.isIdle(first) && store.isIdle(second) }
        if !ended { store.stop(second); _ = await wait(timing.turn, poll: timing.poll) { store.isIdle(second) } }
        let outcome = concurrentOutcome(first: first.messages, second: second.messages, both: both, stopped: stopped, ended: ended)
        let sessions = [first.hermesSessionID, second.hermesSessionID]
        let selfTest = sessions.allSatisfy { $0.map(AppConstants.isSelfTestSession) ?? false }
        step.passed = outcome.passed && selfTest
        step.detail = "sessions \(sessions.map { $0 ?? "-" }.joined(separator: ", ")) | \(outcome.detail)"
            + (secondRunning ? " | the second was still answering at Stop" : "") + (selfTest ? "" : " | not self-test sessions")
        return step
    }

    /// h verdict: both turns ran at once, the first was stopped with its partial kept, and the second finished in full.
    static func concurrentOutcome(first: [ChatMessage], second: [ChatMessage], both: Bool, stopped: Bool, ended: Bool) -> (passed: Bool, detail: String) {
        guard both else { return (false, "the two turns did not run at the same time") }
        guard ended else { return (false, "the replies did not end within the turn limit") }
        let partial = first.last { $0.role == .assistant && $0.presentation == .text }
        let reply = second.last { $0.role == .assistant && $0.presentation == .text }
        let text = oneLine(reply?.content ?? "")
        guard stopped, let partial, partial.turnState == .stopped, !partial.content.isEmpty else {
            return (false, "the first reply was not stopped with its partial kept (\(partial?.turnState.map { "\($0)" } ?? "no reply"))")
        }
        guard let reply, reply.turnState == .finished, text.contains(concurrentToken) else {
            return (false, "Stop on the first left the second incomplete (\(reply?.turnState.map { "\($0)" } ?? "no reply")): \(snippet(text))")
        }
        return (true, "first stopped (\(partial.content.count) chars kept) | second complete: \(snippet(text))")
    }
}
