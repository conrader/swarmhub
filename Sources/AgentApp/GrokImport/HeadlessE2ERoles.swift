import Foundation

/// P13 Part C, `--e2e --roles <provider>/<model> <provider>/<model>`: step g, appended to the six `--e2e` steps.
/// It makes the calls the app's model roles make (Part B's apply-on-create, Part D's coding thread) in new self-test
/// sessions and checks the session stream's `runtime{}` against the pairs given. The pairs come from the command
/// line only; nothing is picked from the catalog (an unrouted guess costs quota and proves nothing).
extension HeadlessE2E {
    struct RolePairs: Equatable { let conversation: ModelChoice; let coding: ModelChoice }

    /// nil when `--roles` is absent; `.failure` with the reason when it is present but not two `provider/model` pairs.
    nonisolated static func rolePairs(arguments: [String]) -> Result<RolePairs, RolesArgumentError>? {
        guard let index = arguments.firstIndex(of: "--roles") else { return nil }
        let values = arguments.dropFirst(index + 1).prefix(2)
        let pairs = values.compactMap { value -> ModelChoice? in
            guard !value.hasPrefix("--"), let slash = value.firstIndex(of: "/") else { return nil }
            return ModelChoice(provider: String(value[..<slash]), model: String(value[value.index(after: slash)...]))
        }
        guard pairs.count == 2 else { return .failure(.init()) }
        return .success(.init(conversation: pairs[0], coding: pairs[1]))
    }

    struct RolesArgumentError: Error, Equatable {
        var text: String { "--roles needs two pairs: --roles <provider>/<model> <provider>/<model> (conversation, then coding)" }
    }

    /// g1 and g2, one line each. g2 continues from g1's chat; without it g2 fails and says why.
    static func rolesSteps(store: AppStore, jarvis: Bot, pairs: RolePairs, timing: Timing) async -> [Step] {
        let bot = copy(jarvis, name: "\(jarvis.name) roles")
        bot.modelSettings = .init(conversation: .choice(pairs.conversation))
        store.bots.append(bot)
        let conversation = await conversationRoleStep(store: store, bot: bot, pair: pairs.conversation, timing: timing)
        let coding = await codingThreadStep(store: store, bot: bot, parent: conversation.assistant, pair: pairs.coding, timing: timing)
        return [conversation.step, coding]
    }

    /// g1: create → apply the conversation pair through the store's apply-on-create path (GET row, lock) → one
    /// message → `runtime{}` equals the pair.
    static func conversationRoleStep(store: AppStore, bot: Bot, pair: ModelChoice, timing: Timing) async -> (step: Step, assistant: ChatMessage?) {
        var step = Step(id: "g1", name: "conversation role", passed: false, detail: "")
        select(bot, in: store)
        let turn = await self.turn(store: store, text: message("Reply with exactly: E2E-ROLECHAT"), conversation: bot, timing: timing)
        let session = bot.hermesSessionID
        let lock = bot.hermesModelLock.flatMap { $0.sessionID == session ? $0 : nil }
        let runtime = await store.lastRuntime(for: bot)
        let row = await sessionRow(store: store, bot: bot, session: session)
        let applied = lock.map { $0.provider == pair.provider && sameModel($0.model, pair.model) } ?? false
        let ran = runtime?.matches(provider: pair.provider, model: pair.model) ?? false
        let replied = turn.error == nil && turn.reply.contains("E2E-ROLECHAT")
        step.passed = applied && ran && replied && (session.map(AppConstants.isSelfTestSession) ?? false)
        step.detail = "session \(session ?? "-") | wanted \(describe(pair)) | lock \(lock.map { "\($0.provider)/\($0.model) (\($0.origin?.rawValue ?? "no origin"))" } ?? "not applied")"
            + " | runtime \(runtime.map(describe) ?? "not reported") | session row \(row) | reply \(replied ? "ok" : (turn.error ?? snippet(turn.reply)))"
        return (step, turn.assistant)
    }

    /// g2: fork with `replyInThread`, lock the fork's session to the coding pair, one message in the thread →
    /// `runtime{}` equals the coding pair. These are the calls Part D's coding thread makes.
    static func codingThreadStep(store: AppStore, bot: Bot, parent: ChatMessage?, pair: ModelChoice, timing: Timing) async -> Step {
        var step = Step(id: "g2", name: "coding thread", passed: false, detail: "")
        select(bot, in: store)
        guard let parent, let parentSession = bot.hermesSessionID else { step.detail = "no (g1) chat to fork"; return step }
        if store.botFeatures[bot.id] == nil { store.refreshFeatures(for: bot) }
        _ = await wait(timing.request, poll: timing.poll) { store.botFeatures[bot.id] != nil }
        guard store.canFork(bot) else { step.detail = "session \(parentSession) | server does not offer session_fork"; return step }
        guard let options = store.botInfo.info(for: bot.id)?.modelOptions.value, ModelPickerModel.offers(options, pair) else {
            step.detail = "session \(parentSession) | \(ModelRoleReason.notOffered(pair.model).text)"; return step
        }
        store.errorMessage = nil
        store.replyInThread(to: parent, in: bot)
        _ = await wait(timing.request, poll: timing.poll) { store.openThreadID != nil || store.errorMessage != nil }
        guard let thread = store.openThread(in: bot), let fork = thread.hermesSessionID else {
            step.detail = "fork of \(parentSession) | \(store.errorMessage ?? "no thread opened")"; return step
        }
        do {
            guard let backend = try store.backend(for: bot) as? HermesBackend else { throw BackendError.unavailable("This bot is not on Hermes.") }
            let lock = try await store.lockModel(backend, bot: bot, sessionID: fork, provider: pair.provider, model: pair.model, origin: .coding, record: false)
            thread.role = .coding; thread.modelLock = lock
        } catch {
            store.closeThread()
            let key = (try? store.backend(for: bot) as? HermesBackend)?.apiKey ?? ""
            step.detail = "fork \(fork) of \(parentSession) | lock \(describe(pair)) refused: \(BotInfoCache.describe(error, key: key))"; return step
        }
        let turn = await self.turn(store: store, text: message("Reply with exactly: E2E-ROLECODE"), conversation: thread, timing: timing)
        store.closeThread()
        let runtime = await store.lastRuntime(for: thread)
        let ran = runtime?.matches(provider: pair.provider, model: pair.model) ?? false
        let replied = turn.error == nil && turn.reply.contains("E2E-ROLECODE")
        step.passed = ran && replied && AppConstants.isSelfTestSession(fork)
        step.detail = "fork \(fork) of \(parentSession) | wanted \(describe(pair)) | lock accepted | runtime \(runtime.map(describe) ?? "not reported")"
            + " | reply \(replied ? "ok" : (turn.error ?? snippet(turn.reply)))"
        return step
    }

    private static func sessionRow(store: AppStore, bot: Bot, session: String?) async -> String {
        guard let session, let backend = try? store.backend(for: bot) as? HermesBackend else { return "not read" }
        return ((try? await backend.sessionModel(sessionID: session)) ?? nil) ?? "no model"
    }

    static func describe(_ pair: ModelChoice) -> String { "\(pair.provider)/\(pair.model)" }
    static func describe(_ runtime: HermesRuntime) -> String { "\(runtime.provider ?? "no provider")/\(runtime.model)" }
}
