import Foundation

/// Changing which agent program and model many bots run on at once. A server's main bot asks for it in its reply
/// (`HerdrModelRequest`), and the person can do the same in Settings → Servers. The app matches the request against
/// what the server offers and changes the setting of each bot. A change the main bot marked "decided", in answer to
/// what the person wrote, is applied at once; any other waits above the composer for Apply or Not now, and so does
/// every change while the main bot's "Ask me before creating bots" is on. What was applied stays on a card with Undo
/// and "Start fresh agents": a bot whose agent is running keeps its model until that agent is started fresh, and
/// the fresh agent reads the bot's chat so far before its first message (`AppStore+HerdrCarryOver.swift`).
extension AppStore {
    /// `UserDefaults`: the changes that were applied, as JSON, newest last.
    static let herdrModelRecordsKey = "herdrModelChanges", herdrModelRecordsKept = 6
    /// A change takes the place of the same asker's earlier one once that is this old. Younger ones stay beside it:
    /// one reply may change some bots to one model and the rest to another.
    static let herdrModelRecordStays: TimeInterval = 600

    /// One request waiting for the person's answer.
    struct PendingHerdrModel: Identifiable, Equatable { let id: String; let request: HerdrModelRequest }

    /// One change that was applied: who asked, what each bot ran on before, and which bots have started fresh since.
    struct HerdrModelRecord: Codable, Equatable, Identifiable {
        var id = UUID()
        /// The main bot that asked; nil when the person did it in Settings.
        var manager: UUID?
        var server: String
        var label: String
        var changes: [HerdrModelPlan.Change]
        var at: Date
        /// The bots whose agent was ended after the change (or had none running), so they start as now chosen.
        var fresh: [UUID] = []
        /// What "Start fresh agents" last came to, in a sentence.
        var note = ""
        /// The person is done with it (Done or Undo), or a newer change took its place: its card is gone.
        var settled = false
        /// The person undid a change after bots had started fresh on it: these bots are back on what they ran
        /// before, and are offered a fresh start on that. It has no Undo of its own.
        var undo = false

        /// The bots that may still run an agent that was started before the change.
        var notFresh: Int { changes.filter { !fresh.contains($0.bot) }.count }
    }

    static func botCount(_ count: Int) -> String { count == 1 ? "1 bot" : "\(count) bots" }

    // MARK: Requests waiting for the person

    /// The model requests in the main bot's newest finished reply that were neither applied nor dismissed. An older
    /// reply's requests are no longer offered once the bot has answered again. Nothing the app is applying right now
    /// is offered.
    func pendingHerdrModels(for bot: Bot) -> [PendingHerdrModel] {
        guard createsHerdrBots(bot), isIdle(bot),
              let newest = bot.messages.suffix(60).last(where: { $0.role == .assistant && $0.presentation == .text && !$0.isStreaming }) else { return [] }
        return herdrModelRequests(in: newest).filter { !herdrSettling.contains($0.id) }
    }

    /// The unhandled model requests of one reply.
    func herdrModelRequests(in reply: ChatMessage) -> [PendingHerdrModel] {
        let handled = Set(defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? [])
        return HerdrModelRequest.requests(in: reply.content).enumerated().compactMap { index, request in
            let id = "\(reply.id.uuidString.lowercased())#\(HerdrModelRequest.op)#\(index)"
            return handled.contains(id) ? nil : PendingHerdrModel(id: id, request: request)
        }
    }

    func herdrModelRequestWaits(_ pending: PendingHerdrModel) -> Bool {
        !(defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? []).contains(pending.id)
    }

    /// The request is settled (applied, refused or dismissed): it is not offered again.
    func dismissHerdrModel(_ pending: PendingHerdrModel) {
        let handled = (defaults.stringArray(forKey: Self.herdrHandledRequestsKey) ?? []).filter { $0 != pending.id } + [pending.id]
        defaults.set(Array(handled.suffix(Self.herdrHandledRequestsKept)), forKey: Self.herdrHandledRequestsKey)
        objectWillChange.send()
    }

    // MARK: What a request comes to

    /// The server's bots as a plan needs them: each one's stored choices, and the template those mean there now.
    func herdrModelTargets(on server: HerdrServer, templates: [HerdrClient.Template]) -> [HerdrModelPlan.Target] {
        let shared = defaults.string(forKey: HerdrBackend.templateKey)
        return herdrBots(on: server).filter { !$0.isReadOnlyArchive && !$0.isDemo }.map { bot in
            let own = defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""
            let template = HerdrAgentReading.template(own: own, shared: shared, in: templates).template?.name
            return HerdrModelPlan.Target(id: bot.id, name: bot.name, ownTemplate: own, template: template, model: herdrModel(for: bot))
        }
    }

    /// The plan for `request` on `server`, from what the server offers now; or why there is none.
    func herdrModelPlan(_ request: HerdrModelRequest, on server: HerdrServer) async -> Result<HerdrModelPlan, HerdrModelRefusal> {
        do {
            let client = try herdrClient(for: server)
            let templates = try await client.workspace().templates.filter { $0.error == nil }
            var offered: [String: [HerdrClient.Template.Model]] = [:]
            // Only a request that names a model needs the lists; one that also names the program needs only that program's.
            if request.model != nil {
                let named = HerdrBotRequest.template(for: request.runtime, in: templates)
                for template in named.map({ [$0] }) ?? templates where template.takesModel {
                    do { offered[template.name] = try await client.models(for: template) }
                    catch {
                        // A list that could not be read is not "no such model": the request waits, unless the template names its models itself.
                        guard let own = template.models, !own.isEmpty else { throw error }
                        offered[template.name] = own
                    }
                }
            }
            return HerdrModelPlan.make(request, bots: herdrModelTargets(on: server, templates: templates), templates: templates, offered: offered)
        } catch { return .failure(.unreadable(error.localizedDescription)) }
    }

    // MARK: Applying

    var herdrModelRecords: [HerdrModelRecord] {
        get { defaults.data(forKey: Self.herdrModelRecordsKey).flatMap { try? JSONDecoder().decode([HerdrModelRecord].self, from: $0) } ?? [] }
        set {
            defaults.set(try? JSONEncoder().encode(Array(newValue.suffix(Self.herdrModelRecordsKept))), forKey: Self.herdrModelRecordsKey)
            objectWillChange.send()
        }
    }

    /// The changes still on their card, oldest first: those `manager` asked for (nil: made in Settings) on `server`.
    func herdrModelRecords(by manager: Bot?, on server: HerdrServer) -> [HerdrModelRecord] {
        herdrModelRecords.filter { !$0.settled && $0.manager == manager?.id && $0.server == server.id }
    }

    /// The newest of them.
    func herdrModelRecord(by manager: Bot?, on server: HerdrServer) -> HerdrModelRecord? { herdrModelRecords(by: manager, on: server).last }

    /// Changes each bot's setting as planned. Returns what was changed, for its card; nil when nothing was.
    /// An agent that was started ahead of time and has not been written to is ended, so the bot's first message
    /// starts one as now chosen. Nothing is started here: a change to many bots must not start an agent for each.
    /// `running`: the agents that run for the server's bots now (nil: not known), so that each changed bot's next
    /// agent is handed the bot's chat.
    @discardableResult func applyHerdrModels(_ plan: HerdrModelPlan, on server: HerdrServer, by manager: Bot?, running: [UUID: HerdrAgentLaunch]? = nil) -> HerdrModelRecord? {
        var changed: [Bot] = []
        for change in plan.changes {
            guard let bot = bots.first(where: { $0.id == change.bot }) else { continue }
            setHerdrTemplate(change.template, for: bot); setHerdrModel(change.model, for: bot)
            changed.append(bot)
        }
        guard !changed.isEmpty else { return nil }
        let record = HerdrModelRecord(manager: manager?.id, server: server.id, label: plan.label,
                                      changes: plan.changes.filter { change in changed.contains { $0.id == change.bot } }, at: now())
        // This change takes the place of the same asker's earlier ones, except those just made (`herdrModelRecordStays`).
        var records = herdrModelRecords
        for index in records.indices where records[index].manager == record.manager && records[index].server == record.server
            && record.at.timeIntervalSince(records[index].at) >= Self.herdrModelRecordStays { records[index].settled = true }
        herdrModelRecords = records + [record]
        if let running { armHerdrCarryOver(for: changed, running: running) }
        endUnusedHerdrAgents(of: changed)
        return record
    }

    private func endUnusedHerdrAgents(of changed: [Bot]) {
        guard launchWorkEnabled else { return }
        Task {
            for bot in changed {
                await herdrWarming[bot.id]?.value
                guard let backend = try? herdrBackend(for: bot) else { continue }
                if (try? await backend.client.endUnused(name: backend.agentName)) == true { herdrReadiness[bot.id] = nil }
            }
        }
    }

    /// Reads the server and applies the request, with a line in the main bot's chat. Returns why not when nothing
    /// could be applied: the request then stays as it was.
    @discardableResult func acceptHerdrModel(_ pending: PendingHerdrModel, manager: Bot) async -> HerdrModelRefusal? {
        let server = herdrServer(for: manager)
        switch await herdrModelPlan(pending.request, on: server) {
        case .failure(let refusal): return refusal
        case .success(let plan):
            // The agents that run now hold their conversations; each changed bot's next agent is handed its chat.
            let running = await herdrRunningLaunches(on: server)
            // Apply pressed twice, or the reply settled meanwhile: the request was handled.
            guard herdrModelRequestWaits(pending) else { return nil }
            dismissHerdrModel(pending)
            guard createsHerdrBots(manager) else { return nil }
            if applyHerdrModels(plan, on: server, by: manager, running: running) != nil {
                notice(AppOnlyLine.modelsChanged.render(manager.name, Self.botCount(plan.changes.count), plan.label), in: manager)
            } else {
                notice(AppOnlyLine.modelsAlready.render(Self.botCount(plan.unchanged), plan.label), in: manager)
            }
            return nil
        }
    }

    /// The main bot's finished reply: a change it marked decided, in answer to what the person wrote, is applied now
    /// (unless its person confirms what it does); every other waits for Apply. A request that cannot be applied goes
    /// back to the main bot once, with what the server has, so it can correct itself; its second miss is only said
    /// in the chat.
    func settleHerdrModels(_ waiting: [PendingHerdrModel], main: Bot, triggers: [ChatMessage]) async {
        defer { herdrSettling.subtract(waiting.map(\.id)); objectWillChange.send() }
        // Only the person's own message makes a change theirs: not one another bot's request led to, and not the app's.
        let asked = triggers.contains { $0.metadata[HerdrBotRelay.Key.kind] == nil && $0.metadata[HerdrIntro.Key.kind] == nil }
        // The answer to "not applied" is the corrected form of what the person asked for.
        let retried = triggers.contains { $0.metadata[HerdrModelRequest.outcomeKey] != nil }
        for pending in waiting {
            guard pending.request.decided, asked || retried, !herdrAsksFirst(main) else { continue }
            guard let refusal = await acceptHerdrModel(pending, manager: main), !refusal.isTemporary else { continue }
            dismissHerdrModel(pending)
            if retried {
                notice(AppOnlyLine.modelsNotChanged.render(main.name, refusal.text), in: main)
            } else {
                herdrPassOn(HerdrModelRequest.notApplied(refusal), to: main, kind: HerdrBotRelay.outcome, asker: main, name: nil, extra: [HerdrModelRequest.outcomeKey: "1"])
            }
        }
    }

    // MARK: Settings

    /// Settings → Servers: every bot on `server` runs `template` on `model` (a model ID, or `HerdrModelChoice.recommended`).
    /// `templates` are the server's, `running` its bots' agents (`applyHerdrModels`). Returns what was changed; nil
    /// when every bot already ran that way.
    @discardableResult func setHerdrModelForAll(on server: HerdrServer, template: HerdrClient.Template, model: String, label: String, templates: [HerdrClient.Template],
                                                running: [UUID: HerdrAgentLaunch]? = nil) -> HerdrModelRecord? {
        let changes = herdrModelTargets(on: server, templates: templates).filter { $0.template != template.name || $0.model != model }.map { target in
            HerdrModelPlan.Change(bot: target.id, name: target.name, template: template.name, model: model, beforeTemplate: target.ownTemplate, beforeModel: target.model)
        }
        return applyHerdrModels(HerdrModelPlan(changes: changes, unchanged: 0, label: label), on: server, by: nil, running: running)
    }

    // MARK: The card of a change

    private func updateHerdrModelRecord(_ id: UUID, _ change: (inout HerdrModelRecord) -> Void) {
        var records = herdrModelRecords
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        herdrModelRecords = records
    }

    /// The person is done with the card.
    func doneWithHerdrModels(_ record: HerdrModelRecord) { updateHerdrModelRecord(record.id) { $0.settled = true } }

    /// Puts each bot back on what it ran before. A bot whose choice was changed again since keeps that choice.
    /// Returns how many went back. Going back is a change too: a bot that had started fresh on the new choice
    /// runs that until it is started fresh again, so those bots stay on a card that offers it, and each bot's
    /// next agent is handed its chat (`running`: the agents that run now; nil when not known).
    @discardableResult func undoHerdrModels(_ record: HerdrModelRecord, running: [UUID: HerdrAgentLaunch]? = nil) -> Int {
        guard !record.undo, herdrModelRecords.contains(where: { $0.id == record.id && !$0.settled }) else { return 0 }
        var back: [Bot] = [], again: [HerdrModelPlan.Change] = []
        for change in record.changes {
            guard let bot = bots.first(where: { $0.id == change.bot }) else { continue }
            let own = defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? ""
            guard own == change.template, herdrModel(for: bot) == change.model else { continue }
            setHerdrTemplate(change.beforeTemplate, for: bot); setHerdrModel(change.beforeModel, for: bot)
            back.append(bot)
            if record.fresh.contains(bot.id) {
                again.append(HerdrModelPlan.Change(bot: bot.id, name: bot.name, template: change.beforeTemplate, model: change.beforeModel, beforeTemplate: change.template, beforeModel: change.model))
            }
        }
        doneWithHerdrModels(record)
        if !again.isEmpty {
            herdrModelRecords = herdrModelRecords + [HerdrModelRecord(manager: record.manager, server: record.server, label: record.label, changes: again, at: now(), undo: true)]
        }
        if let running { armHerdrCarryOver(for: back, running: running) }
        endUnusedHerdrAgents(of: back)
        if let manager = record.manager.flatMap({ id in bots.first { $0.id == id } }) {
            notice(AppOnlyLine.modelsUndone.render(record.label, Self.botCount(back.count)), in: manager)
        }
        return back.count
    }

    /// Ends the running agents of the bots a change moved, so each starts as now chosen with its next message, and
    /// reads the bot's chat so far first (it was noted for that when the change was applied). A bot that is
    /// answering is left alone and can be started fresh later; a bot already started fresh is not ended again.
    /// Returns what it came to, in a sentence, which the card keeps.
    @discardableResult func startFreshHerdrAgents(_ record: HerdrModelRecord) async -> String {
        var fresh = record.fresh, started = 0, busy = 0, failed = 0
        for change in record.changes where !fresh.contains(change.bot) {
            guard let bot = bots.first(where: { $0.id == change.bot }) else { fresh.append(change.bot); continue }
            guard isIdle(bot) else { busy += 1; continue }
            do {
                _ = try await restartHerdrAgent(for: bot)
                clearModelSwitch(bot.id)
                clearAutoSwitch(bot.id)
                herdrAgentEndedForChange(bot)
                fresh.append(bot.id); started += 1
            } catch { failed += 1 }
        }
        var parts = [started == 0 ? "No bot was started fresh." : "\(Self.botCount(started)) \(started == 1 ? "starts" : "start") fresh with \(started == 1 ? "its" : "their") next message."]
        if busy > 0 { parts.append("\(Self.botCount(busy)) \(busy == 1 ? "is" : "are") answering and \(busy == 1 ? "keeps its" : "keep their") model until started fresh.") }
        if failed > 0 { parts.append("\(Self.botCount(failed)) could not be reached.") }
        let note = parts.joined(separator: " ")
        let done = fresh
        updateHerdrModelRecord(record.id) { $0.fresh = done; $0.note = note }
        return note
    }
}
