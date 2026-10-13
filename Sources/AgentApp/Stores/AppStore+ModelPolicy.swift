import Foundation

/// A per-bot Conversation override the box refused: the send stops with this plain error (P13 D3).
struct ModelRefusal: LocalizedError { let text: String; var errorDescription: String? { text } }

/// P13 Part B: applies the resolved Conversation model when Torvli starts a chat (main chat or group member).
/// Inert until configured: with no Torvli default and no bot override nothing extra is requested.
extension AppStore {
    var storeFile: StoreFile { StoreFile(bots: bots, groups: groups, modelDefaults: modelDefaults.isEmpty ? nil : modelDefaults) }

    /// What to lock once the session exists.
    struct ModelPlan { let choice: ModelChoice; let origin: LockOrigin; let backend: HermesBackend }

    /// Before the session is created: resolves the bot's Conversation role, loads (or reuses) its capabilities and
    /// model options, and refuses a pair its own list lacks. A refused override throws; a refused default posts
    /// `note` and returns nil, so the message goes out on the box default.
    func prepareModel(for bot: Bot, backend: any AgentBackend, note: (String) -> Void) async throws -> ModelPlan? {
        let resolved = ModelPolicy.resolve(role: .conversation, settings: bot.modelSettings, defaults: modelDefaults)
        guard let choice = resolved.choice, let hermes = backend as? HermesBackend else { return nil }
        let origin: LockOrigin = resolved.source == .bot ? .bot : .torvliDefault
        await botInfo.load(botID: bot.id, sessionID: bot.hermesSessionID, using: hermes, includeSkills: false)
        let info = botInfo.info(for: bot.id)
        let blocked: String?
        if let reason = ModelRoleReason.blocker(info) { blocked = reason.text }
        else if let options = info?.modelOptions.value { blocked = ModelPickerModel.offers(options, choice) ? nil : ModelRoleReason.notOffered(choice.model).text }
        else if case .failed(let reason) = info?.modelOptions { blocked = reason }
        else { blocked = ModelRoleReason.noList.text }
        guard let blocked else { return .init(choice: choice, origin: origin, backend: hermes) }
        try skipModel(choice, origin: origin, bot: bot, reason: blocked, note: note)
        return nil
    }

    /// After create: reads the session row and locks only a new session (no model yet, or the virtual alias); a
    /// session the 409 "exists" path returned keeps its standing model. `record` is false for group sessions.
    func applyModel(_ plan: ModelPlan, bot: Bot, sessionID: String, record: Bool, note: (String) -> Void) async throws {
        do {
            if let row = try await plan.backend.sessionModel(sessionID: sessionID), !modelAliases(for: bot).contains(row) { return }
            try await lockModel(plan.backend, bot: bot, sessionID: sessionID, provider: plan.choice.provider, model: plan.choice.model, origin: plan.origin, record: record)
        } catch let error as ModelRefusal { throw error }
        catch {
            let reason = if case BackendError.http(409, _) = error { "Hermes cannot route \(plan.choice.model) for this chat and will not fall back to the default." }
                else { BotInfoCache.describe(error, key: plan.backend.apiKey) }
            try skipModel(plan.choice, origin: plan.origin, bot: bot, reason: reason, note: note)
        }
    }

    /// D3: an override stops the send; a default is skipped with one note and `modelError`.
    private func skipModel(_ choice: ModelChoice, origin: LockOrigin, bot: Bot, reason: String, note: (String) -> Void) throws {
        if origin == .bot { throw ModelRefusal(text: "\(choice.model), this bot's model, was not applied: \(reason) Nothing was sent.") }
        let text = "Torvli's default model \(choice.model) was not applied: \(reason) This chat runs on the box default."
        note(text)
        botInfo.finishSwitch(botID: bot.id, error: text)
    }

    /// The one write path (P3's lock, shared by the manual picker, apply-on-create and Switch this chat): lock, then
    /// record with its origin and save.
    @discardableResult func lockModel(_ backend: HermesBackend, bot: Bot, sessionID: String, provider: String, model: String, origin: LockOrigin?, record: Bool = true) async throws -> HermesModelLock {
        var lock = try await backend.lockSessionModel(sessionID: sessionID, provider: provider, model: model)
        lock.origin = origin
        if record { bot.hermesModelLock = lock; save(); botInfo.setSessionModel(botID: bot.id, sessionID: sessionID, model: lock.model) }
        return lock
    }

    /// Inserts a system note just before `assistant` (native turns send only the last user message, so notes never
    /// reach Hermes); one identical note is not repeated back to back.
    func insertNote(_ text: String, in conversation: any Conversation, before assistant: ChatMessage) {
        guard conversation.messages.last(where: { $0.role == .system })?.content != text else { return }
        let index = conversation.messages.firstIndex { $0.id == assistant.id } ?? conversation.messages.endIndex
        conversation.messages.insert(ChatMessage(role: .system, content: text), at: index)
        objectWillChange.send()
    }

    /// Overview "Switch this chat": pins the chat to what the bot resolves to now, or to the box's current default
    /// pair when it resolves to the box default (Hermes has no unpin).
    func switchChatToRoleModel(for bot: Bot) async {
        let resolved = ModelPolicy.resolve(role: .conversation, settings: bot.modelSettings, defaults: modelDefaults)
        let options = botInfo.info(for: bot.id)?.modelOptions.value
        guard let provider = resolved.choice?.provider ?? options?.defaultProvider?.slug, let model = resolved.choice?.model ?? options?.model else {
            botInfo.finishSwitch(botID: bot.id, error: ModelRoleReason.noList.text); return
        }
        let origin: LockOrigin? = switch resolved.source { case .bot: .bot; case .torvliDefault: .torvliDefault; default: bot.modelSettings?.conversation == .box ? .bot : nil }
        await switchModel(for: bot, provider: provider, model: model, origin: origin)
    }
}
