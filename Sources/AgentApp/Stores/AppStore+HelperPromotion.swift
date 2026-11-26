import Foundation

struct PromotedHelper: Codable, Equatable {
    let serverID: String
    let core: String
    let session: HerdrClient.AgentRef
    let parentID: UUID
    var pendingAfter: Int?
    var awaitingTask: String?
    var handoffID: UUID?
    struct NativeSession: Codable, Equatable {
        let runtime: HerdrClient.ChildRuntime
        let id: String
        var awaitingResult: Bool
    }
    var native: NativeSession?
    var awaitsReply: Bool { pendingAfter != nil || native?.awaitingResult == true }
    static let rowKey = "promotedHelperRow"
    static let noticeKey = "promotedHelperNotice"
}

extension HerdrClient {
    /// History pages run newest to oldest. Collect every saved conversation row in journal order.
    func helperConversation(_ session: AgentRef, core: String, after: Int = 0) async throws -> [Item] {
        var cursor: Int?
        var rows: [Item] = []
        repeat {
            let page = try await historyPage(core: core, address: session.address, createdMs: session.createdMs, before: cursor)
            rows.append(contentsOf: page.items.filter { $0.id > after && ($0.reachedAgent || $0.kind == "reply") && !$0.text.isEmpty })
            guard let earlier = page.before, earlier > after else { break }
            guard cursor.map({ earlier < $0 }) ?? true else { throw Failure.notDelivered("Could not read the complete helper history.") }
            cursor = earlier
        } while true
        return rows.sorted { $0.id < $1.id }
    }
}

extension AppStore {
    func promotedBot(for helper: HerdrClient.AgentRef, core: String, parent: Bot, runtime: HerdrClient.ChildRuntime? = nil, thread: String? = nil) -> Bot? {
        bots.first {
            guard let source = $0.promotedHelper else { return false }
            return source.native?.runtime == runtime && source.native?.id == thread && source.core == core && source.session == helper && source.parentID == parent.id && source.serverID == herdrServer(for: parent).id
        }
    }

    private func promotedRow(_ item: HerdrClient.Item) -> ChatMessage {
        let row = ChatMessage(role: item.kind == "reply" ? .assistant : .user, content: item.text,
                              createdAt: item.atMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? now(),
                              metadata: [PromotedHelper.rowKey: String(item.id)])
        if item.kind == "reply", let model = item.codexModel {
            row.runSummary = RunSummary(model: model, modelSource: item.codexRerouted == true ? .rerouted : .configured, seconds: nil, tools: 0)
        }
        return row
    }

    func promoteHelper(_ helper: HerdrClient.Helper, core: String, selection: HerdrHelperSelection, of parent: Bot) async throws -> Bot {
        let server = herdrServer(for: parent)
        guard selection.botID == parent.id, selection.helperID == helper.id, bots.contains(parent) else { throw CancellationError() }
        if let existing = promotedBot(for: helper.ref, core: core, parent: parent) { return existing }
        guard persistenceEnabled, storeRestoreOffer == nil, let list = herdrHelpers[selection.parent], list.core == core,
              list.sidebarSessions.contains(where: { $0.ref == helper.ref }) else {
            throw BackendError.unavailable("Reopen this helper from its parent chat to promote it.")
        }
        let client = try herdrClient(for: server)
        let fresh = try await client.helpers(of: list.parent, core: selection.archive == nil ? nil : core)
        guard fresh.core == core, fresh.parent == list.parent,
              let source = fresh.sidebarSessions.first(where: { $0.ref == helper.ref }) else {
            throw BackendError.unavailable("The workspace could not confirm this helper’s identity.")
        }
        let rows = try await client.helperConversation(source.ref, core: core)
        try Task.checkCancellation()
        guard bots.contains(parent), herdrServer(for: parent) == server, storeRestoreOffer == nil else { throw CancellationError() }
        if let existing = promotedBot(for: source.ref, core: core, parent: parent) { return existing }

        var history = rows.map(promotedRow)
        if !rows.contains(where: \.reachedAgent), let task = source.task, !task.isEmpty {
            history.insert(ChatMessage(role: .user, content: task, metadata: [PromotedHelper.rowKey: "assignment"]), at: 0)
        }
        // The delegated task continues in place. Only its next outstanding reply belongs to this handoff.
        let awaiting = source.isLive && source.answered != true && rows.last?.kind != "reply"
        let origin = PromotedHelper(serverID: server.id, core: core, session: source.ref, parentID: parent.id,
                                    pendingAfter: awaiting ? rows.last?.id ?? 0 : nil,
                                    awaitingTask: awaiting && rows.isEmpty ? source.assignment : nil)
        return try savePromotedBot(named: source.name, from: parent, origin: origin, history: history,
                                   template: source.template ?? herdrTemplate(for: parent) ?? "", model: source.model)
    }

    func savePromotedBot(named base: String, from parent: Bot, origin: PromotedHelper, history: [ChatMessage],
                         template: String, model: String?) throws -> Bot {
        var name = base, suffix = 2
        while bots.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(suffix)"; suffix += 1
        }
        let notice = AppOnlyLine.line(origin.awaitsReply
            ? "You can message \(name) now. Its outstanding helper result will appear here."
            : "Earlier work is from \(parent.name)’s helper.")
        notice.metadata[PromotedHelper.noticeKey] = "1"
        let bot = Bot(name: name, title: "Helper from \(parent.name)", backend: .herdr, messages: history + [notice])
        bot.promotedHelper = origin
        setHerdrServer(origin.serverID, for: bot)
        setHerdrTemplate(template, for: bot)
        setHerdrModel(model ?? HerdrModelChoice.recommended, for: bot)
        setHerdrCarryOver(.init(old: nil, at: now()), for: bot)
        bots.insert(bot, at: 0)
        save()
        if turns.saveFailing {
            bots.removeAll { $0.id == bot.id }
            forgetHerdrCarryOver(bot.id)
            for key in [HerdrServer.botKey(bot.id), HerdrBackend.botTemplateKey(bot.id), HerdrBackend.botModelKey(bot.id)] { defaults.removeObject(forKey: key) }
            throw BackendError.unavailable("Could not save the promoted bot. Try again.")
        }
        return bot
    }

    func collectPromotedReplies(on server: HerdrServer, workspace: HerdrClient.Workspace, client: HerdrClient) async {
        for bot in herdrBots(on: server) where bot.promotedHelper?.awaitsReply == true {
            await collectPromotedReply(for: bot, on: server, workspace: workspace, client: client)
        }
    }

    func collectPromotedReply(for bot: Bot, on server: HerdrServer, workspace: HerdrClient.Workspace,
                              client: HerdrClient, preparingDirectTurn: Bool = false) async {
        guard let source = bot.promotedHelper, source.serverID == server.id, source.awaitsReply,
              preparingDirectTurn || !isAnswering(bot) else { return }
        if let native = source.native {
            await collectNativeResult(native, source: source, bot: bot, server: server, client: client, preparingDirectTurn: preparingDirectTurn)
            return
        }
        guard let after = source.pendingAfter else { return }
        let live = workspace.core == source.core && workspace.agents.contains { $0.ref == source.session && $0.isLive }
        guard let rows = try? await client.helperConversation(source.session, core: source.core, after: after),
              !Task.isCancelled, bots.contains(bot), bot.promotedHelper == source, herdrServer(for: bot) == server,
              preparingDirectTurn || !isAnswering(bot) else { return }
        // The parent roster can report a new launch before its first task appears in history.
        // Bind to that task once it arrives. A later, unrelated assignment belongs to the parent.
        var events = rows[...]
        if let expected = source.awaitingTask, let first = events.first, first.reachedAgent, first.text == expected {
            events = events.dropFirst()
            bot.promotedHelper?.awaitingTask = nil
            bot.promotedHelper?.pendingAfter = first.id
            if events.isEmpty && live { save(); return }
        }
        let answer = events.prefix { !$0.reachedAgent }.first { $0.kind == "reply" }
        let notice = bot.messages.first { $0.metadata[PromotedHelper.noticeKey] != nil }
        if let answer {
            notice?.content = "The original helper’s reply is saved above."
            let message = promotedRow(answer)
            let index = bot.messages.lastIndex { $0.metadata[PromotedHelper.rowKey] != nil }.map { $0 + 1 } ?? 0
            bot.messages.insert(message, at: index)
            bot.promotedHelper?.handoffID = UUID()
            setHerdrCarryOver(.init(old: nil, at: now()), for: bot)
            if !showsDirectChat(bot) { bot.unreadCount += 1 }
        } else if live && events.isEmpty { return }
        else { notice?.content = "The original helper task ended without a saved reply." }
        bot.promotedHelper?.awaitingTask = nil
        bot.promotedHelper?.pendingAfter = nil
        save()
    }
}
