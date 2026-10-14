import Foundation
import Security

/// `AgentApp --e2e`: a short live check of the chat features against the real server, driven through the same
/// `AppStore` calls the UI makes (send, steer, reply in thread, model switch, group send, Routines refresh).
/// It runs in a throwaway store holding copies of Jarvis, DMT and Achilles (profile, server and persona only),
/// so the real store, the bots' existing chats and the imported groups are never opened for writing. Every
/// session it creates is new and named `swarmhub-selftest-…` (`AppConstants.selfTestPrefix`); every message starts with `preamble`.
@MainActor enum HeadlessE2E {
    static let preamble = "[\(AppConstants.name) self-test — reply briefly, take no actions]"
    static let namespace = AppConstants.selfTestPrefix

    struct Step: Equatable {
        let id: String; let name: String; var passed: Bool; var detail: String
        var line: String { "\(passed ? "PASS" : "FAIL") \(id) \(name) | \(detail)" }
    }

    struct Participants { let jarvis: Bot; let dmt: Bot; let achilles: Bot }

    struct Timing {
        var turn: Duration = .seconds(240)
        var steerStart: Duration = .seconds(90)
        var request: Duration = .seconds(30)
        var poll: Duration = .milliseconds(100)
    }

    static func message(_ text: String) -> String { "\(preamble) \(text)" }

    /// A copy that talks to the same profile with the same key, but has no messages and no session.
    static func copy(_ bot: Bot, name: String? = nil) -> Bot {
        let copy = Bot(name: name ?? bot.name, title: bot.title, persona: bot.persona, backend: .hermes, avatarName: bot.avatarName, hermesProfile: bot.hermesProfile)
        copy.avatarMark = bot.avatarMark
        copy.hermesBaseURL = bot.hermesBaseURL
        return copy
    }

    // MARK: Entry point

    static func run(arguments: [String]) -> Int32 {
        SecKeychainSetUserInteractionAllowed(false)
        let realURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appending(path: "AgentApp/store.json")
        let saved: StoreFile
        do { saved = try StoreFile.decode(Data(contentsOf: realURL)) } catch { print("E2E failed: cannot read \(realURL.path): \(error.localizedDescription)"); return 1 }
        let directory = FileManager.default.temporaryDirectory.appending(path: "\(namespace)\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tag = String(directory.lastPathComponent.suffix(8))
        var originals: [Bot] = []
        for name in ["Jarvis", "DMT", "Achilles"] {
            guard let bot = find(name, in: saved.bots) else { print("E2E failed: no Hermes bot named \(name) in the store"); return 1 }
            originals.append(bot)
        }
        let store = AppStore(storeURL: directory.appending(path: "store.json"), autoConfigureHermes: false)
        // Jarvis's copy gets a unique name because Hermes refuses a second session with the same title.
        let bots = Participants(jarvis: copy(originals[0], name: "\(originals[0].name) \(namespace)\(tag)"), dmt: copy(originals[1]), achilles: copy(originals[2]))
        store.bots = [bots.jarvis, bots.dmt, bots.achilles]; store.groups = []; store.selectedBot = nil
        print("E2E: test store \(directory.path) (removed afterwards); real store \(realURL.path) is read only, \(saved.groups.count) groups in it are not loaded")
        return HeadlessRunLoop.wait {
            let steps = await run(store: store, bots: bots, tag: tag, output: { print($0); fflush(stdout) })
            return steps.allSatisfy(\.passed) && steps.count == 6 ? 0 : 1
        }
    }

    /// A Grok-imported bot first, then any visible one; never a read-only archive.
    static func find(_ name: String, in bots: [Bot]) -> Bot? {
        let named = bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return named.first { $0.grokSourceID != nil && !$0.isHidden } ?? named.first { !$0.isHidden } ?? named.first
    }

    // MARK: Steps

    /// Runs steps a–f in order, printing one line per step. All bots in `bots` must already be in `store`.
    static func run(store: AppStore, bots: Participants, tag: String = "test", timing: Timing = .init(), output: (String) -> Void) async -> [Step] {
        store.sessionNamespace = namespace
        var steps: [Step] = []
        func record(_ step: Step) { steps.append(step); output(step.line) }

        let chat = await chatStep(store: store, bot: bots.jarvis, timing: timing); record(chat.step)
        record(await steerStep(store: store, jarvis: bots.jarvis, timing: timing))
        record(await forkStep(store: store, bot: bots.jarvis, parent: chat.assistant, timing: timing))
        record(await modelStep(store: store, bot: bots.jarvis, timing: timing))
        record(await groupStep(store: store, bots: bots, tag: tag, timing: timing))
        record(await routinesStep(store: store, bot: bots.jarvis))
        output("E2E: \(steps.filter(\.passed).count) passed, \(steps.filter { !$0.passed }.count) failed")
        return steps
    }

    static func chatStep(store: AppStore, bot: Bot, timing: Timing) async -> (step: Step, assistant: ChatMessage?) {
        select(bot, in: store)
        let turn = await self.turn(store: store, text: message("Reply with exactly: E2E-CHAT"), conversation: bot, timing: timing)
        return (expect(turn, "E2E-CHAT", id: "a", name: "chat"), turn.assistant)
    }

    /// Steers a running count with a second message; an accepted steer the model ignores still passes.
    static func steerStep(store: AppStore, jarvis: Bot, timing: Timing) async -> Step {
        let bot = copy(jarvis, name: "\(jarvis.name) steer")
        store.bots.append(bot); select(bot, in: store)
        var step = Step(id: "b", name: "steer", passed: false, detail: "")
        store.errorMessage = nil
        guard store.send(text: message("Count slowly from 1 to 20, one number per line")) else { step.detail = "not sent: \(store.errorMessage ?? "send refused")"; return step }
        let assistant = store.streamingAssistant
        // `steerAvailable` is settled before the first token is read from the stream.
        let tokens = await wait(timing.steerStart, poll: timing.poll) { store.isIdle || !(assistant?.content.isEmpty ?? true) }
        guard tokens, !store.isIdle else {
            if !tokens { store.stop() }
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | " + (tokens ? "turn ended before the first tokens could be steered" : "no tokens within \(timing.steerStart)") + (store.errorMessage.map { " (\($0))" } ?? "")
            return step
        }
        guard store.send(text: message("Stop counting and reply with exactly: E2E-STEER")) else {
            await finish(store, timing: timing)
            step.detail = "session \(bot.hermesSessionID ?? "-") | steer not offered (run_steer=\(store.steerAvailable))"
            return step
        }
        let steer = bot.messages.last { $0.isSteer }
        _ = await wait(timing.request, poll: timing.poll) { steer?.metadata["steer"] != "sent" }
        let ended = await finish(store, timing: timing)
        _ = await wait(timing.request, poll: timing.poll) { steer?.metadata["steer"] != "sent" }
        let outcome = steer?.metadata["steer"] ?? "missing"
        let final = oneLine(assistant?.content ?? "")
        let session = "session \(bot.hermesSessionID ?? "-")"
        guard outcome == "delivered" else {
            let reason = bot.messages.last { $0.role == .system && $0.content.hasPrefix("Steer not delivered") }?.content ?? "steer state \(outcome)"
            step.detail = "\(session) | \(reason)"; return step
        }
        guard ended else { step.detail = "\(session) | steer accepted (HTTP 2xx) but the turn did not finish within \(timing.turn)"; return step }
        step.passed = true
        step.detail = "\(session) | steer accepted (HTTP 2xx) | " + (final.contains("E2E-STEER") ? "final: \(snippet(final))" : "accepted-but-ignored, final: \(snippet(final))")
        return step
    }

    static func forkStep(store: AppStore, bot: Bot, parent: ChatMessage?, timing: Timing) async -> Step {
        var step = Step(id: "c", name: "fork", passed: false, detail: "")
        select(bot, in: store)
        guard let parent, let parentSession = bot.hermesSessionID else { step.detail = "no (a) session to fork"; return step }
        store.botFeatures[bot.id] = nil; store.refreshFeatures(for: bot)
        _ = await wait(timing.request, poll: timing.poll) { store.botFeatures[bot.id] != nil }
        guard store.canFork(bot) else { step.detail = "session \(parentSession) | server does not offer session_fork"; return step }
        store.errorMessage = nil
        store.replyInThread(to: parent, in: bot)
        _ = await wait(timing.request, poll: timing.poll) { store.openThreadID != nil || store.errorMessage != nil }
        guard let thread = store.openThread(in: bot), thread.parentMessageID == parent.id else { step.detail = "session \(parentSession) | \(store.errorMessage ?? "no thread opened")"; return step }
        let turn = await self.turn(store: store, text: message("Reply with exactly: E2E-FORK"), conversation: thread, timing: timing)
        store.closeThread()
        step = expect(turn, "E2E-FORK", id: "c", name: "fork")
        step.detail = "fork of \(parentSession) -> " + step.detail
        return step
    }

    /// Switches the (a) session to another offered model, sends one turn, reads the session back, then switches back.
    static func modelStep(store: AppStore, bot: Bot, timing: Timing) async -> Step {
        var step = Step(id: "d", name: "model", passed: false, detail: "")
        select(bot, in: store)
        guard let session = bot.hermesSessionID else { step.detail = "no (a) session"; return step }
        await store.loadServerInfo(for: bot, force: true)
        guard let info = store.botInfo.info(for: bot.id), let options = info.modelOptions.value else {
            step.detail = "session \(session) | no model options: \(store.botInfo.info(for: bot.id).map { "\($0.modelOptions)" } ?? "no server info")"; return step
        }
        guard info.canLockSessionModel else { step.detail = "session \(session) | server cannot lock a session's model"; return step }
        guard let original = store.currentModel(for: bot) else { step.detail = "session \(session) | current model unknown"; return step }
        let originalProvider = original.provider ?? options.provider ?? ""
        let providers = options.selectable.filter { $0.slug == originalProvider } + options.selectable.filter { $0.slug != originalProvider }
        let candidates = providers
            .flatMap { provider in provider.models.map { (provider: provider.slug, model: $0) } }
            .filter { !sameModel($0.model, original.model) }
        guard !candidates.isEmpty else { step.detail = "session \(session) | only \(original.model) is offered"; return step }
        var chosen: (provider: String, model: String)?; var refusals: [String] = []
        for candidate in candidates.prefix(3) {
            await store.switchModel(for: bot, provider: candidate.provider, model: candidate.model)
            if let error = store.botInfo.info(for: bot.id)?.modelError { refusals.append("\(candidate.model): \(error)"); continue }
            if let lock = bot.hermesModelLock, lock.sessionID == session, sameModel(lock.model, candidate.model) { chosen = candidate; break }
        }
        guard let chosen else { step.detail = "session \(session) | no other model accepted: \(refusals.joined(separator: "; "))"; return step }
        let turn = await self.turn(store: store, text: message("Reply with exactly: E2E-MODEL"), conversation: bot, timing: timing)
        await store.loadServerInfo(for: bot, force: true)
        let reported = store.botInfo.info(for: bot.id)?.sessionModel
        let shown = store.currentModel(for: bot)?.model ?? "-"
        let replied = turn.error == nil && turn.reply.contains("E2E-MODEL")
        let confirmed = reported.map { sameModel($0, chosen.model) } ?? false
        await store.switchModel(for: bot, provider: originalProvider, model: original.model)
        let backError = store.botInfo.info(for: bot.id)?.modelError
        let restored = backError == nil && bot.hermesModelLock.map { $0.sessionID == session && sameModel($0.model, original.model) } == true
        await store.loadServerInfo(for: bot, force: true)
        let restoredShown = store.currentModel(for: bot)?.model ?? "-"
        step.passed = replied && confirmed && restored && sameModel(restoredShown, original.model)
        step.detail = "session \(session) | \(original.model) -> \(chosen.provider)/\(chosen.model): reply \(replied ? "ok" : "FAILED (\(turn.error ?? snippet(turn.reply)))"), session reports \(reported ?? "no model"), chat shows \(shown) | back to \(original.model): \(restored ? "accepted" : "FAILED (\(backError ?? "lock not confirmed"))"), chat shows \(restoredShown)"
        return step
    }

    /// A temporary group with DMT and Achilles; only DMT is mentioned, so only DMT may answer. The group is deleted afterwards.
    static func groupStep(store: AppStore, bots: Participants, tag: String, timing: Timing) async -> Step {
        var step = Step(id: "e", name: "group", passed: false, detail: "")
        store.errorMessage = nil
        guard let group = store.createGroup(name: "\(namespace)group \(tag)", memberIDs: [bots.dmt.id, bots.achilles.id]) else { step.detail = store.errorMessage ?? "group not created"; return step }
        let before = Set(group.messages.map(\.id))
        if store.send(text: message("@\(bots.dmt.name) reply with exactly: E2E-GROUP"), to: group) {
            let ended = await wait(timing.turn, poll: timing.poll) { store.isIdle }
            if !ended { store.stop(); _ = await finish(store, timing: timing) }
        } else { step.detail = "not sent: \(store.errorMessage ?? "send refused")" }
        let answers = group.messages.filter { !before.contains($0.id) && $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let notes = group.messages.filter { !before.contains($0.id) && $0.role == .system }.map(\.content)
        let authors = Set(answers.compactMap(\.authorID))
        let reply = oneLine(answers.first { $0.authorID == bots.dmt.id }?.content ?? "")
        let dmtSession = group.session(for: bots.dmt.id) ?? "-"
        let achillesSession = group.session(for: bots.achilles.id)
        store.deleteGroup(group)
        let deleted = !store.groups.contains { $0.id == group.id }
        let error = store.errorMessage
        step.passed = step.detail.isEmpty && authors == [bots.dmt.id] && reply.contains("E2E-GROUP") && achillesSession == nil && deleted && error == nil
        if step.detail.isEmpty {
            let who = authors.isEmpty ? "nobody" : authors.map { id in id == bots.dmt.id ? bots.dmt.name : id == bots.achilles.id ? bots.achilles.name : "?" }.sorted().joined(separator: "+")
            step.detail = "DMT session \(dmtSession) | answered: \(who)\(achillesSession.map { ", Achilles session \($0)" } ?? "") | reply: \(snippet(reply))"
                + (notes.isEmpty ? "" : " | notes: \(notes.joined(separator: "; "))") + (error.map { " | error: \($0)" } ?? "")
                + " | temporary group \(deleted ? "deleted" : "NOT deleted")"
        }
        return step
    }

    /// Read-only: the Routines tab's list call (`GET /api/jobs`) for Jarvis's profile.
    static func routinesStep(store: AppStore, bot: Bot) async -> Step {
        await store.refreshRoutines(for: bot)
        let state = store.routines.state(for: bot.id)
        let profile = bot.hermesProfile ?? "default"
        switch state.jobs {
        case .loaded(let jobs):
            let paused = jobs.filter(\.isPaused).count
            return .init(id: "f", name: "routines", passed: true, detail: "\(profile): \(jobs.count) jobs\(paused > 0 ? " (\(paused) paused)" : "") listed, nothing changed")
        case .loading: return .init(id: "f", name: "routines", passed: false, detail: "\(profile): still loading")
        case .unavailable(let reason), .failed(let reason): return .init(id: "f", name: "routines", passed: false, detail: "\(profile): \(reason)")
        }
    }

    // MARK: Helpers

    struct Turn { var reply = ""; var error: String?; var session: String?; var assistant: ChatMessage? }

    /// Sends `text` the way the composer does and waits for the turn to end.
    static func turn(store: AppStore, text: String, conversation: any Conversation, timing: Timing) async -> Turn {
        store.errorMessage = nil
        let before = Set(conversation.messages.map(\.id))
        guard store.send(text: text) else { return .init(error: "not sent: \(store.errorMessage ?? "send refused")", session: conversation.hermesSessionID) }
        guard await wait(timing.turn, poll: timing.poll, { store.isIdle }) else {
            store.stop(); _ = await finish(store, timing: timing)
            return .init(error: "no reply within \(timing.turn)", session: conversation.hermesSessionID)
        }
        let assistant = conversation.messages.last { !before.contains($0.id) && $0.role == .assistant && $0.presentation == .text }
        return .init(reply: oneLine(assistant?.content ?? ""), error: store.errorMessage, session: conversation.hermesSessionID, assistant: assistant)
    }

    static func expect(_ turn: Turn, _ token: String, id: String, name: String) -> Step {
        let session = "session \(turn.session ?? "-")"
        if let error = turn.error { return .init(id: id, name: name, passed: false, detail: "\(session) | \(error)") }
        let ok = turn.reply.contains(token) && (turn.session.map(AppConstants.isSelfTestSession) ?? false)
        return .init(id: id, name: name, passed: ok, detail: "\(session) | reply: \(snippet(turn.reply))")
    }

    /// Selects a chat like a sidebar click, without the history refresh (a fresh test session has none).
    static func select(_ bot: Bot, in store: AppStore) {
        if store.selectedBot?.id != bot.id { store.openThreadID = nil }
        store.selectedBot = bot; store.selectedGroup = nil
    }

    @discardableResult static func finish(_ store: AppStore, timing: Timing) async -> Bool { await wait(timing.turn, poll: timing.poll) { store.isIdle } }

    static func wait(_ timeout: Duration, poll: Duration, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock(); let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
        }
        return true
    }

    static func sameModel(_ a: String, _ b: String) -> Bool { HermesModelOptions.sameModel(a, b) }
    static func oneLine(_ text: String) -> String { text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ").trimmingCharacters(in: .whitespaces) }
    static func snippet(_ text: String) -> String { text.isEmpty ? "(empty)" : text.count > 160 ? String(text.prefix(160)) + "…" : text }
}
