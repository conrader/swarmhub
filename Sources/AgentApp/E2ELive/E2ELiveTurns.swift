import Foundation

/// uxfix1-e2e turns, each in a fresh `swarmhub-selftest-…` session of a copy (never a bot's own chat): a steer typed
/// mid-turn lands without stopping the turn (`--e2e` b1 and b2), and two real connection drops (`E2ELiveRelay`): one
/// in the middle of a streaming reply, one while a message is being sent. Neither may open the alert; both must recover.
extension E2ELive {
    static func turnSteps(store: AppStore, manager: Bot, run: Run) async {
        let timing = HeadlessE2E.Timing()
        for step in [await HeadlessE2E.steerTextStep(store: store, jarvis: manager, timing: timing),
                     await HeadlessE2E.steerToolStep(store: store, jarvis: manager, timing: timing)] {
            let bot = store.bots.last { $0.name.hasPrefix("\(manager.name) steer") && $0.hermesSessionID != nil && step.detail.contains($0.hermesSessionID!) }
            let stopped = bot?.messages.filter { $0.role == .assistant && $0.turnState == .stopped }.count ?? -1
            run.check("steer.\(step.id)", step.passed && stopped == 0, "\(step.name): \(step.detail); stopped replies=\(stopped)")
        }
        guard let source = store.bots.first(where: { !store.isManager($0) && !$0.name.contains("steer") }) ?? store.bots.first else { return }
        await dropMidStream(store: store, source: source, run: run, timing: timing)
        await dropWhileSending(store: store, source: source, run: run, timing: timing)
    }

    /// The tunnel is cut while the reply streams and stays down 8 s; then the chat must work again by itself.
    static func dropMidStream(store: AppStore, source: Bot, run: Run, timing: HeadlessE2E.Timing) async {
        let bot = HeadlessE2E.copy(source, name: "\(source.name) net"); bot.notificationsEnabled = false
        store.bots.append(bot); HeadlessE2E.select(bot, in: store)
        let before = run.modals.count
        guard store.send(text: HeadlessE2E.message("Count slowly from 1 to 40, one number per line, then write E2E-NET")) else {
            run.check("net.midstream", false, "not sent: \(store.errorMessage ?? "-")"); return
        }
        let reply = store.turn(in: bot)?.assistant
        let streaming = await HeadlessE2E.wait(.seconds(120), poll: .milliseconds(50)) { store.isIdle(bot) || !(reply?.content.isEmpty ?? true) }
        guard streaming, !store.isIdle(bot) else { await HeadlessE2E.finish(store, timing: timing); run.check("net.midstream", false, "no streaming reply to cut"); return }
        run.relay.drop(for: 8)
        run.note("E2E-LIVE: dropped mid-stream (\(run.relay.counts))")
        let ended = await HeadlessE2E.wait(.seconds(300), poll: .milliseconds(100)) { store.isIdle(bot) }
        let sameTurn = reply.map { "\($0.turnState.map { "\($0)" } ?? "-") \(HeadlessE2E.snippet(HeadlessE2E.oneLine($0.content)))" } ?? "-"
        _ = await HeadlessE2E.wait(.seconds(15), poll: .milliseconds(200)) { !run.relay.isDown }
        let next = await HeadlessE2E.turn(store: store, text: HeadlessE2E.message("Reply with exactly: E2E-NET-AFTER"), conversation: bot, timing: timing)
        let cleared = await HeadlessE2E.wait(.seconds(10), poll: .milliseconds(100)) { store.connectionNotice == nil }
        let ok = ended && run.modals.count == before && next.error == nil && next.reply.contains("E2E-NET-AFTER") && cleared
        run.check("net.midstream", ok, "cut turn ended=\(ended) [\(sameTurn)]; next turn: \(next.error ?? HeadlessE2E.snippet(next.reply)); connection line cleared=\(cleared); alerts during=\(run.modals.count - before); \(run.relay.counts)")
    }

    /// The tunnel goes down for 6 s and a message is sent at once: it must be resent by itself ("Reconnecting…") and answered.
    static func dropWhileSending(store: AppStore, source: Bot, run: Run, timing: HeadlessE2E.Timing) async {
        let bot = HeadlessE2E.copy(source, name: "\(source.name) offline"); bot.notificationsEnabled = false
        store.bots.append(bot); HeadlessE2E.select(bot, in: store)
        let before = run.modals.count
        run.relay.drop(for: 6)
        var reconnecting = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if store.turn(in: bot)?.assistant?.metadata["status"] == TurnErrorCopy.reconnecting || store.turn(in: bot)?.assistant?.metadata[TurnKey.reconnecting] != nil { reconnecting = true }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let turn = await HeadlessE2E.turn(store: store, text: HeadlessE2E.message("Reply with exactly: E2E-OFFLINE"), conversation: bot, timing: timing)
        watcher.cancel()
        let cleared = await HeadlessE2E.wait(.seconds(10), poll: .milliseconds(100)) { store.connectionNotice == nil }
        let ok = turn.error == nil && turn.reply.contains("E2E-OFFLINE") && turn.assistant?.turnState == .finished && run.modals.count == before && cleared
        run.check("net.offline-send", ok, "reply: \(turn.error ?? HeadlessE2E.snippet(turn.reply)); state=\(turn.assistant?.turnState.map { "\($0)" } ?? "-"); showed Reconnecting=\(reconnecting); connection line cleared=\(cleared); alerts during=\(run.modals.count - before); \(run.relay.counts)")
    }
}
