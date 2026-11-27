import Foundation

extension AppStore {
    /// A CLI child shares its owner's terminal. Its identity also includes the provider and thread.
    func promoteNativeHelper(_ selection: HerdrHelperSelection, of parent: Bot) async throws -> Bot {
        guard let native = selection.native, selection.botID == parent.id, bots.contains(parent),
              native.server == herdrServer(for: parent), selection.helperID == native.thread.id else { throw CancellationError() }
        let runtime = native.thread.provider
        let threadID = native.thread.id
        func existing() -> Bot? {
            promotedBot(for: native.owner, core: native.core, parent: parent, runtime: runtime, thread: threadID)
        }
        if let bot = existing() { return bot }
        guard persistenceEnabled, storeRestoreOffer == nil,
              let list = herdrHelpers[selection.parent], list.core == native.core, list.parent == native.owner,
              list.nativeThreads.contains(where: { $0.provider == runtime && $0.id == threadID }) else {
            throw BackendError.unavailable("Reopen this helper from its parent chat to promote it.")
        }
        let client = try herdrClient(for: native.server)
        let fresh = try await client.helpers(of: native.owner, core: native.core)
        guard fresh.parent == native.owner, fresh.core == native.core,
              let child = fresh.nativeThreads.first(where: { $0.provider == runtime && $0.id == threadID }) else {
            throw BackendError.unavailable("The workspace could not confirm this helper’s identity.")
        }
        let activity = try await client.threadActivity(runtime, owner: native.owner, core: native.core, thread: threadID)
        let workspace = try await client.workspace()
        try Task.checkCancellation()
        guard bots.contains(parent), native.server == herdrServer(for: parent), storeRestoreOffer == nil else { throw CancellationError() }
        if let bot = existing() { return bot }
        let program = HerdrProgramName.friendly(display: nil, program: runtime.label)?.lowercased()
        let matching = workspace.templates.filter { template in
            template.error == nil && HerdrProgramName.friendly(display: nil, program: template.runtime?.harness ?? template.modelAgent)?.lowercased() == program
        }
        let launched = workspace.core == native.core ? workspace.agents.first { $0.ref == native.owner }?.template : nil
        guard let template = matching.first(where: { $0.name == launched })
                ?? matching.first(where: { $0.name == herdrTemplate(for: parent) }) ?? matching.first else {
            throw BackendError.unavailable("Install or enable " + runtime.label + " on this workspace to promote this session.")
        }
        let waiting = activity.state == "working" || activity.state == "unavailable"
        let origin = PromotedHelper(serverID: native.server.id, core: native.core, session: native.owner, parentID: parent.id,
                                    native: .init(runtime: runtime, id: threadID, awaitingResult: waiting))
        var history: [ChatMessage] = []
        if let task = HelperAssignment.readable(activity.details?.task ?? "") ?? HelperAssignment.readable(child.task) {
            history.append(ChatMessage(role: .user, content: task, metadata: [PromotedHelper.rowKey: "assignment"]))
        }
        if let record = nativeSessionRecord(activity) {
            history.append(ChatMessage(role: .assistant, content: record, metadata: [PromotedHelper.rowKey: "session"]))
        }
        return try savePromotedBot(named: child.name, from: parent, origin: origin, history: history,
                                   template: template.name, model: template.takesModel ? child.model : nil)
    }

    private func nativeSessionRecord(_ activity: HerdrClient.ThreadActivity) -> String? {
        let transcript = HelperAssignment.transcript(activity.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = activity.details?.reply.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if transcript.isEmpty { return reply.isEmpty ? nil : reply }
        // Some providers keep a longer reply in the details than in their terminal preview.
        return reply.isEmpty || transcript.contains(reply) ? transcript : transcript + "\n\n" + reply
    }

    /// Refresh the imported session record in place. Ordinary messages in the new chat keep their order.
    func collectNativeResult(_ native: PromotedHelper.NativeSession, source: PromotedHelper, bot: Bot, server: HerdrServer,
                             client: HerdrClient, preparingDirectTurn: Bool) async {
        guard let activity = try? await client.threadActivity(native.runtime, owner: source.session, core: source.core, thread: native.id),
              ["answered", "finished", "stopped", "error"].contains(activity.state),
              !Task.isCancelled, bots.contains(bot), bot.promotedHelper == source, herdrServer(for: bot) == server,
              preparingDirectTurn || !isAnswering(bot) else { return }
        if let text = nativeSessionRecord(activity) {
            if let index = bot.messages.firstIndex(where: { $0.metadata[PromotedHelper.rowKey] == "session" }) {
                let record = bot.messages[index]
                if text.contains(record.content) {
                    record.content = text
                } else if !record.content.contains(text) {
                    // Providers may trim earlier output between reads. Keep the imported record as well.
                    let result = ChatMessage(role: .assistant, content: text, metadata: [PromotedHelper.rowKey: "finishedSession"])
                    bot.messages.insert(result, at: index + 1)
                }
            } else {
                let index = bot.messages.firstIndex { $0.metadata[PromotedHelper.noticeKey] != nil } ?? 0
                bot.messages.insert(ChatMessage(role: .assistant, content: text, metadata: [PromotedHelper.rowKey: "session"]), at: index)
            }
            // Put the late result in the next prompt even when newer direct messages fill the normal excerpt.
            let reply = activity.details?.reply ?? ""
            let excerpt = reply.isEmpty
                ? String(SecretFilter.redacted(text, replacement: GrokRedactor.marker).suffix(2000))
                : GrokHandoff.cleanSummary(reply)
            bot.promotedHelper?.native?.pendingReplyExcerpt = excerpt.isEmpty ? nil : excerpt
            bot.promotedHelper?.handoffID = UUID()
            setHerdrCarryOver(.init(old: nil, at: now()), for: bot)
            if !showsDirectChat(bot) { bot.unreadCount += 1 }
        }
        let notice = bot.messages.first { $0.metadata[PromotedHelper.noticeKey] != nil }
        notice?.content = "Original helper session: " + HerdrClient.NativeThread.statusLabel(activity.state) + "."
        bot.promotedHelper?.native?.awaitingResult = false
        save()
    }
}
