import Foundation

/// uxfix1-e2e installs: every SwarmHub skill on every bot copy, through the buttons' own calls: "Install on all bots"
/// (`installSkillsOnAllBots`), then each bot's Install (`installSkills(for:)`) for what is left. While the first install
/// turn runs, two messages typed into the manager's composer must wait and then go once each, in order (A then B).
/// Then the record (no skill needing action, no failure) and the box itself (`GET /v1/skills`, read only) are checked.
extension E2ELive {
    static let installTimeout: Duration = .seconds(45 * 60)
    static let queuedTokens = ("E2E-QA", "E2E-QB")

    static func installSteps(store: AppStore, manager: Bot, run: Run) async {
        let gaps = store.messagingSkillGaps(manager: manager)
        run.note("E2E-LIVE: all-bots gaps \(gaps.count) bots, \(gaps.reduce(0) { $0 + $1.installable.count }) skills")
        HeadlessE2E.select(manager, in: store)
        let started = store.installSkillsOnAllBots(manager: manager)
        run.check("install.all.start", started, started ? "the all-bots install started" : "refused: \(store.errorMessage ?? "-")")
        guard started else { return }
        await queueTwo(store: store, manager: manager, run: run)
        let allDone = await HeadlessE2E.wait(installTimeout, poll: .milliseconds(250)) { installIdle(store, manager) }
        run.check("install.all.finish", allDone, allDone ? "batch ended; \(results(store))" : "batch still running after \(installTimeout)")
        await checkQueued(store: store, manager: manager, run: run)

        for bot in store.bots where store.skills(for: bot).contains(where: { store.skillState($0, for: bot).needsAction }) {
            let wanted = store.skills(for: bot).filter { store.skillState($0, for: bot).needsAction }.map(\.name)
            let sent = store.installSkills(for: bot)
            var done = false
            if sent { done = await HeadlessE2E.wait(.seconds(15 * 60), poll: .milliseconds(250)) { installIdle(store, manager) } }
            run.note("E2E-LIVE: install \(bot.name) \(wanted.joined(separator: ",")): sent=\(sent) done=\(done) \(store.skillInstallResults[bot.id].map { "\($0.status) \($0.detail.prefix(160))" } ?? "")")
        }

        var missing: [String] = []
        for bot in store.bots {
            for skill in store.skills(for: bot) where store.skillState(skill, for: bot).needsAction { missing.append("\(bot.name)/\(skill.name)=\(store.skillState(skill, for: bot))") }
            for (name, failure) in bot.skillInstallFailures { missing.append("\(bot.name)/\(name) failed: \(failure.reason.prefix(160))") }
        }
        let total = store.bots.reduce(0) { $0 + store.skills(for: $1).count }
        run.check("install.record", missing.isEmpty, "\(total - missing.count)/\(total) skills current on \(store.bots.count) bots" + (missing.isEmpty ? "" : "; " + missing.prefix(12).joined(separator: "; ")))
        await checkBox(store: store, run: run)
    }

    /// No install turn, batch, queued message or pending install left on the manager.
    static func installIdle(_ store: AppStore, _ manager: Bot) -> Bool {
        store.isIdle(manager) && store.allBotsSkillQueue[manager.id] == nil && store.pendingSkillInstalls[manager.id] == nil && !store.hasWaitingTurn(in: manager)
    }

    static func results(_ store: AppStore) -> String {
        let all = store.bots.compactMap { store.skillInstallResults[$0.id]?.status }
        return Dictionary(grouping: all, by: { "\($0)" }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
    }

    // MARK: Queued A + B

    /// Types A then B into the manager's composer while its install turn runs: both must wait (an install is never steered).
    static func queueTwo(store: AppStore, manager: Bot, run: Run) async {
        let running = await HeadlessE2E.wait(.seconds(120), poll: .milliseconds(100)) {
            store.turn(in: manager)?.assistant.map { AppStore.isSetupRow($0, in: manager, bot: manager) } ?? false
        }
        guard running else { run.check("queue.wait", false, "no install turn running to queue behind"); return }
        HeadlessE2E.select(manager, in: store)
        let a = store.send(text: HeadlessE2E.message("Reply with exactly: \(queuedTokens.0)"))
        let b = store.send(text: HeadlessE2E.message("Reply with exactly: \(queuedTokens.1)"))
        let waiting = manager.messages.filter { $0.metadata[TurnWaitCopy.key] == "waiting" }.count
        run.check("queue.wait", a && b && waiting == 2 && !store.isIdle(manager), "A sent=\(a) B sent=\(b), waiting rows=\(waiting), install turn still running=\(!store.isIdle(manager))")
    }

    /// A and B each reached the box once, in order, and each got its own answer.
    static func checkQueued(store: AppStore, manager: Bot, run: Run) async {
        let rows = manager.messages
        func userRows(_ token: String) -> [Int] { rows.indices.filter { rows[$0].role == .user && rows[$0].content.contains("exactly: \(token)") } }
        func answer(after index: Int) -> String {
            rows[(index + 1)...].first { $0.role == .assistant && $0.presentation == .text }.map { HeadlessE2E.oneLine($0.content) } ?? ""
        }
        let a = userRows(queuedTokens.0), b = userRows(queuedTokens.1)
        let local = a.count == 1 && b.count == 1 && a[0] < b[0] && answer(after: a[0]).contains(queuedTokens.0) && answer(after: b[0]).contains(queuedTokens.1)
        var box = "no session"
        var boxOK = false
        if let session = manager.hermesSessionID, let backend = try? store.backend(for: manager) {
            do {
                let sent = try await backend.loadMessages(sessionID: session).filter { $0.role == "user" }.map(\.content)
                let countA = sent.filter { $0.contains("exactly: \(queuedTokens.0)") }.count, countB = sent.filter { $0.contains("exactly: \(queuedTokens.1)") }.count
                let order = (sent.firstIndex { $0.contains("exactly: \(queuedTokens.0)") } ?? .max) < (sent.firstIndex { $0.contains("exactly: \(queuedTokens.1)") } ?? .max)
                boxOK = countA == 1 && countB == 1 && order
                box = "box session \(session): A×\(countA) B×\(countB) in order=\(order)"
            } catch { box = "GET messages failed: \(error.localizedDescription)" }
        }
        let detail = "local A rows=\(a.count) B rows=\(b.count); A answer: \(HeadlessE2E.snippet(a.first.map(answer) ?? "")); B answer: \(HeadlessE2E.snippet(b.first.map(answer) ?? "")); \(box)"
        run.check("queue.once.in.order", local && boxOK, detail)
    }

    // MARK: The box

    /// `GET /v1/skills` per profile (read only): every SwarmHub skill meant for the bot is listed at the bundled version.
    static func checkBox(store: AppStore, run: Run) async {
        var ok = 0, bad: [String] = []
        for bot in store.bots {
            guard let backend = try? store.backend(for: bot) as? HermesBackend else { bad.append("\(bot.name): no backend"); continue }
            do {
                let listed = try await backend.skills().filter { $0.category == SkillLibrary.category }
                for skill in store.skills(for: bot) {
                    let row = listed.first { $0.name == skill.name }
                    let version = row.flatMap { $0.version ?? SkillLibrary.advertisedVersion(in: $0.description) }
                    if version == skill.version.description { ok += 1 } else { bad.append("\(bot.name)/\(skill.name)=\(version ?? (row == nil ? "absent" : "unversioned"))") }
                }
            } catch { bad.append("\(bot.name): GET /v1/skills \(error.localizedDescription)") }
        }
        run.check("install.box", bad.isEmpty, "\(ok) skills at the bundled version on the box" + (bad.isEmpty ? "" : "; " + bad.prefix(12).joined(separator: "; ")))
    }
}
