import Foundation

/// Changing which agent program and model many bots run on at once. A server's main bot asks for it in its reply
/// (`HerdrModelRequest`), and the person can do the same in Settings → Servers. The app matches the request against
/// what the server offers and changes the setting of each bot. A change the main bot marked "decided", in answer to
/// what the person wrote, is applied at once; any other waits above the composer for Apply or Not now. Idle agents
/// are ended so their next message starts a fresh agent with the same chat. Busy agents switch on the next direct
/// message. What was applied stays on a card with Undo.
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
        /// What happened to the running sessions when the change was applied.
        var rolloverSummary: String? = nil
        /// The person is done with it (Done or Undo), or a newer change took its place: its card is gone.
        var settled = false
        /// The person restored the bots' previous settings. This card has no Undo of its own.
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

    /// Saves the choices, then rolls over idle sessions. Returns nil when there were no changes left to apply.
    @discardableResult func applyHerdrModels(_ plan: HerdrModelPlan, on server: HerdrServer, by manager: Bot?) async -> HerdrModelRecord? {
        let targets = herdrBots(on: server).filter { !$0.isReadOnlyArchive && !$0.isDemo }
        let changes = plan.changes.filter { change in
            guard let bot = targets.first(where: { $0.id == change.bot }),
                  hasHerdrModelChoice(bot, template: change.beforeTemplate, model: change.beforeModel) else { return false }
            setHerdrTemplate(change.template, for: bot)
            setHerdrModel(change.model, for: bot)
            return true
        }
        guard !changes.isEmpty else { return nil }
        let record = HerdrModelRecord(manager: manager?.id, server: server.id, label: plan.label, changes: changes, at: now())
        // This change takes the place of the same asker's earlier ones, except those just made (`herdrModelRecordStays`).
        var records = herdrModelRecords
        for index in records.indices where records[index].manager == record.manager && records[index].server == record.server
            && record.at.timeIntervalSince(records[index].at) >= Self.herdrModelRecordStays { records[index].settled = true }
        herdrModelRecords = records + [record]
        return await startFreshHerdrAgents(record)
    }

    /// Reads the server and applies the request, with a line in the main bot's chat. Returns why not when nothing
    /// could be applied: the request then stays as it was.
    @discardableResult func acceptHerdrModel(_ pending: PendingHerdrModel, manager: Bot) async -> HerdrModelRefusal? {
        let server = herdrServer(for: manager)
        switch await herdrModelPlan(pending.request, on: server) {
        case .failure(let refusal): return refusal
        case .success(let plan):
            // Apply pressed twice, or the reply settled meanwhile: the request was handled.
            guard herdrModelRequestWaits(pending) else { return nil }
            dismissHerdrModel(pending)
            guard createsHerdrBots(manager), herdrMainBot(on: server)?.id == manager.id else { return nil }
            if let record = await applyHerdrModels(plan, on: server, by: manager) {
                let heading = AppOnlyLine.modelsChanged.render(manager.name, Self.botCount(record.changes.count), record.label)
                notice([heading, record.rolloverSummary].compactMap { $0 }.joined(separator: " "), in: manager)
            } else {
                notice(AppOnlyLine.modelsAlready.render(Self.botCount(plan.unchanged), plan.label), in: manager)
            }
            return nil
        }
    }

    /// The main bot's finished reply: a change it marked decided, in answer to what the person wrote, is applied now
    /// while every other waits for Apply. A request that cannot be applied goes
    /// back to the main bot once, with what the server has, so it can correct itself; its second miss is only said
    /// in the chat.
    func settleHerdrModels(_ waiting: [PendingHerdrModel], main: Bot, triggers: [ChatMessage]) async {
        defer { herdrSettling.subtract(waiting.map(\.id)); objectWillChange.send() }
        // Only the person's own message makes a change theirs: not one another bot's request led to, and not the app's.
        let asked = triggers.contains { $0.metadata[HerdrBotRelay.Key.kind] == nil && $0.metadata[HerdrIntro.Key.kind] == nil }
        // The answer to "not applied" is the corrected form of what the person asked for.
        let retried = triggers.contains { $0.metadata[HerdrModelRequest.outcomeKey] != nil }
        for pending in waiting {
            guard pending.request.decided, asked || retried else { continue }
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
    /// Returns what was changed, or nil when every bot already ran that way.
    @discardableResult func setHerdrModelForAll(on server: HerdrServer, template: HerdrClient.Template, model: String, label: String,
                                                templates: [HerdrClient.Template]) async -> HerdrModelRecord? {
        let changes = herdrModelTargets(on: server, templates: templates).filter { $0.template != template.name || $0.model != model }.map { target in
            HerdrModelPlan.Change(bot: target.id, name: target.name, template: template.name, model: model, beforeTemplate: target.ownTemplate, beforeModel: target.model)
        }
        return await applyHerdrModels(HerdrModelPlan(changes: changes, unchanged: 0, label: label), on: server, by: nil)
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
    /// Rolls over the restored bots in the same way as the original change. Returns how many went back.
    @discardableResult func undoHerdrModels(_ record: HerdrModelRecord) async -> Int {
        guard !record.undo, herdrModelRecords.contains(where: { $0.id == record.id && !$0.settled }) else { return 0 }
        doneWithHerdrModels(record)
        let targets = herdrServer(id: record.server).map(herdrBots(on:)) ?? []
        let restored = record.changes.compactMap { change -> HerdrModelPlan.Change? in
            guard let bot = targets.first(where: { $0.id == change.bot }),
                  hasHerdrModelChoice(bot, template: change.template, model: change.model) else { return nil }
            setHerdrTemplate(change.beforeTemplate, for: bot)
            setHerdrModel(change.beforeModel, for: bot)
            return HerdrModelPlan.Change(bot: bot.id, name: bot.name, template: change.beforeTemplate, model: change.beforeModel,
                                         beforeTemplate: change.template, beforeModel: change.model)
        }
        guard !restored.isEmpty else { return 0 }
        let reversal = HerdrModelRecord(manager: record.manager, server: record.server, label: record.label, changes: restored, at: now(), undo: true)
        herdrModelRecords = herdrModelRecords + [reversal]
        let result = await startFreshHerdrAgents(reversal)
        if let manager = record.manager.flatMap({ id in bots.first { $0.id == id } }) {
            let heading = AppOnlyLine.modelsUndone.render(record.label, Self.botCount(restored.count))
            notice([heading, result.rolloverSummary].compactMap { $0 }.joined(separator: " "), in: manager)
        }
        return restored.count
    }

    private func hasHerdrModelChoice(_ bot: Bot, template: String, model: String) -> Bool {
        (defaults.string(forKey: HerdrBackend.botTemplateKey(bot.id)) ?? "") == template && herdrModel(for: bot) == model
    }

    /// Ends idle and unused agents. Bots answering or waiting on a prompt keep their session until the next send.
    /// The next agent receives the bot's chat, including any reply that was still in progress.
    private func startFreshHerdrAgents(_ record: HerdrModelRecord) async -> HerdrModelRecord {
        var fresh = record.fresh, busy = 0, failed = 0
        if let server = herdrServer(id: record.server) {
            let byID = Dictionary(uniqueKeysWithValues: herdrBots(on: server).map { ($0.id, $0) })
            func stillApplies(_ bot: Bot, _ change: HerdrModelPlan.Change) -> Bool {
                bots.contains(bot) && herdrServer(for: bot) == server
                    && hasHerdrModelChoice(bot, template: change.template, model: change.model)
            }
            // Apply and Undo each record changes for one server. Let all of its pending warm starts finish
            // before reading the workspace once for the whole batch.
            let candidates = record.changes.compactMap { change -> (Bot, HerdrModelPlan.Change)? in
                guard !fresh.contains(change.bot), let bot = byID[change.bot], stillApplies(bot, change) else { return nil }
                return (bot, change)
            }
            for (bot, _) in candidates { await herdrWarming[bot.id]?.value }
            let current = candidates.filter { stillApplies($0.0, $0.1) }
            do {
                if !current.isEmpty {
                    let client = try herdrClient(for: server)
                    let workspace = try await client.workspace()
                    guard let core = workspace.core else {
                        throw BackendError.unavailable("Herdr Core is not running on the server.")
                    }
                    for (bot, change) in current where stillApplies(bot, change) {
                        guard modelSwitchPending(bot) else { fresh.append(bot.id); continue }
                        let name = HerdrBackend.agentName(botName: bot.name, botID: bot.id)
                        let agent = client.liveAgent(named: name, in: workspace)
                        let running = agent.map { [bot.id: HerdrAgentLaunch(server: server.id, core: core, address: $0.address, createdMs: $0.createdMs)] } ?? [:]
                        armHerdrCarryOver(for: [bot], running: running)
                        if herdrBotIsBusy(bot) || agent.map({ !$0.isIdleForRollover || herdrAgentIsBusy($0, in: workspace.agents) }) == true {
                            busy += 1
                            continue
                        }
                        do {
                            if let agent { try await client.end(agent) }
                        } catch { failed += 1; continue }
                        guard stillApplies(bot, change) else { continue }
                        if !runningTurns.values.contains(where: { $0.botID == bot.id }) { forgetHerdrAgentState(for: bot) }
                        clearModelSwitch(bot.id)
                        clearAutoSwitch(bot.id)
                        fresh.append(bot.id)
                    }
                }
            } catch { failed = current.filter { stillApplies($0.0, $0.1) }.count }
        }
        var parts = ["\(Self.botCount(fresh.count)) \(fresh.count == 1 ? "is" : "are") ready to use the selected model now."]
        if busy > 0 { parts.append("\(Self.botCount(busy)) will switch on the next direct message after the current turn.") }
        if failed > 0 { parts.append("The choice was saved for \(Self.botCount(failed)) whose sessions could not be checked or ended.") }
        var result = record
        result.fresh = fresh
        result.rolloverSummary = parts.joined(separator: " ")
        updateHerdrModelRecord(record.id) { $0.fresh = result.fresh; $0.rolloverSummary = result.rolloverSummary }
        return result
    }
}
