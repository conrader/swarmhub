import Foundation

/// P13 Part D: "Switch existing chats…" (main chats only), threads that keep their parent's lock, and coding threads.
extension AppStore {
    func modelRolesPlanInput(for bot: Bot) -> ModelRolesPlan.Input {
        .init(id: bot.id, name: bot.name, block: catalogBlock(for: bot)?.text, sessionID: bot.hermesSessionID, isStreaming: isStreamingIn(bot),
              lock: bot.hermesModelLock, current: currentModel(for: bot), catalog: modelCatalog(for: bot),
              blocker: ModelRoleReason.blocker(botInfo.info(for: bot.id)), settings: bot.modelSettings, defaults: modelDefaults)
    }

    /// The preview; reads only what Load already put in the cache (no request).
    func modelRolesPlan() -> ModelRolesPlan { ModelRolesPlan(modelRoleBots.map(modelRolesPlanInput)) }

    /// Confirm: one lock per bot that still would change, one at a time, each re-checked just before its POST (a bot
    /// that started answering or whose target moved since the preview is skipped). A failure never stops the rest.
    func runModelRolesPlan(_ plan: ModelRolesPlan) async -> [UUID: String] {
        var results: [UUID: String] = [:]
        for planned in plan.changing {
            guard let bot = bots.first(where: { $0.id == planned.id }) else { results[planned.id] = "removed"; continue }
            let row = ModelRolesPlan.row(modelRolesPlanInput(for: bot))
            guard row.willChange, row.to == planned.to, let pair = row.to, let sessionID = bot.hermesSessionID else {
                results[bot.id] = row.skip?.text ?? "changed since the preview; nothing was sent"; continue
            }
            var key = ""
            do {
                guard let backend = try backend(for: bot) as? HermesBackend else { throw BackendError.unavailable("This bot is not on Hermes.") }
                key = backend.apiKey
                let lock = try await lockModel(backend, bot: bot, sessionID: sessionID, provider: pair.provider, model: pair.model, origin: row.origin)
                results[bot.id] = "switched to \(lock.model)"
            } catch {
                results[bot.id] = "failed: " + lockFailure(error, model: pair.model, key: key)
            }
        }
        return results
    }

    func lockFailure(_ error: Error, model: String, key: String, place: String = "chat") -> String {
        if case BackendError.http(409, _) = error { return "Hermes cannot route \(model) for this \(place) and will not fall back to the default." }
        return BotInfoCache.describe(error, key: key)
    }

    // MARK: Threads

    /// The pair "Code in thread" locks a fork to: the bot's Coding role when it is a concrete pair (and its list, if
    /// loaded, offers it) that differs from what the main chat runs; nil hides the button.
    func codingThreadChoice(for bot: Bot) -> ModelChoice? {
        guard bot.backend == .hermes else { return nil }
        let effective = ModelPolicy.effective(role: .coding, settings: bot.modelSettings, defaults: modelDefaults, catalog: modelCatalog(for: bot).value)
        guard let choice = effective.choice, effective.check != .notOffered else { return nil }
        if let current = currentModel(for: bot), ModelCatalog.sameModel(current.model, choice.model) { return nil }
        return choice
    }

    /// Fork → lock the fork to the Coding choice → open it as "Coding · <model>". Fails closed: no thread and an inline
    /// error when the lock is refused (the orphan fork on the box is harmless).
    func codeInThread(to message: ChatMessage, in bot: Bot) {
        if let existing = bot.thread(for: message.id) { openThreadID = existing.id; return }
        guard let choice = codingThreadChoice(for: bot) else { return }
        startThread(from: message, in: bot, coding: choice)
    }

    /// Forks the bot's session; a plain thread then re-locks to the parent's recorded lock (a fork drops the lock),
    /// a coding thread locks to `coding`. With no lock to carry nothing more is sent. The thread appears only once
    /// every step succeeded.
    func startThread(from message: ChatMessage, in bot: Bot, coding: ModelChoice? = nil) {
        guard canFork(bot), let sessionID = bot.hermesSessionID, !isStreaming else { return }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) } catch { errorMessage = error.localizedDescription; return }
        let parentLock = bot.hermesModelLock.flatMap { $0.sessionID == sessionID ? $0 : nil }
        let target = coding.map { ($0.provider, $0.model, LockOrigin.coding) } ?? parentLock.map { ($0.provider, $0.model, $0.origin) }
        let failure = coding == nil ? "Could not start a thread: " : "Could not start a coding thread: "
        let threadID = UUID()
        Task {
            if let coding, let reason = await codingRefusal(coding, bot: bot) { errorMessage = failure + reason; return }
            let forkID: String
            do { forkID = try await activeBackend.forkSession(sessionID: sessionID, id: "\(sessionNamespace)agentapp_thread_\(threadID.uuidString.lowercased())") }
            catch {
                errorMessage = failure + error.localizedDescription
                refreshFeatures(for: bot) // a Gateway that rejected the fork parameters hides Reply in thread (P12)
                return
            }
            let thread = ChatThread(id: threadID, parentMessageID: message.id, parentSessionID: sessionID, hermesSessionID: forkID)
            if let (provider, model, origin) = target {
                guard let hermes = activeBackend as? HermesBackend else { errorMessage = failure + "This bot is not on Hermes."; return }
                do { thread.modelLock = try await lockModel(hermes, bot: bot, sessionID: forkID, provider: provider, model: model, origin: origin, record: false) }
                catch { errorMessage = failure + lockFailure(error, model: model, key: hermes.apiKey, place: "thread"); return }
                if coding != nil { thread.role = .coding }
            }
            guard bot.thread(for: message.id) == nil else { return }
            bot.threads.append(thread)
            if selectedBot?.id == bot.id { openThreadID = threadID }
            objectWillChange.send(); save()
        }
    }

    /// Why the Coding pair cannot be applied, after loading (or reusing) this bot's list; nil when it can.
    private func codingRefusal(_ choice: ModelChoice, bot: Bot) async -> String? {
        await loadServerInfo(for: bot, includeSkills: false)
        if let reason = ModelRoleReason.blocker(botInfo.info(for: bot.id)) { return reason.text }
        switch modelCatalog(for: bot) {
        case .loaded(let catalog): return catalog.offers(choice) ? nil : ModelRoleReason.notOffered(choice.model).text
        case .failed(let reason), .unavailable(let reason): return reason
        case .loading: return ModelRoleReason.noList.text
        }
    }
}
