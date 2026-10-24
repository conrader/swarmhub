import Foundation

/// autoctx1 metadata: `setup` marks the rows of an app-internal turn (never history, never reconciled against the chat's
/// session); `boundary` marks the line where a chat continued in a new session (history sent before it is not resent).
enum ContextKey { static let setup = "setupTurn", boundary = "sessionBoundary" }

enum ContextRecovery {
    enum Step: Equatable { case none, compacted, newSession }
    enum Action: Equatable { case resend(Step), stop(String) }
}

/// autoctx1: app-internal turns run in a throwaway session; a chat that outgrew the model's context recovers by itself.
extension AppStore {
    static let setupRetryDelays: [Duration] = [.seconds(2), .seconds(8)]

    /// The session `token`'s turn talks to: its own throwaway one while it has one, else the chat's.
    func turnSessionID(_ token: UUID, in conversation: any Conversation, bot: Bot) -> String {
        turns.sessions[token] ?? conversation.hermesSessionID ?? bot.id.uuidString
    }

    static func lastUserOnly(_ history: [(role: String, content: String)]) -> [(role: String, content: String)] {
        history.last(where: { $0.role == "user" }).map { [$0] } ?? history
    }

    // MARK: Setup sessions

    func markSetupTurn(_ assistant: ChatMessage, in conversation: any Conversation) {
        assistant.metadata[ContextKey.setup] = "1"
        conversation.messages.last { $0.role == .user && $0.createdAt <= assistant.createdAt }?.metadata[ContextKey.setup] = "1"
    }

    /// A fresh session for this setup attempt (`agentapp_setup_<uuid>`), listed for deletion before it is created.
    func openSetupSession(bot: Bot, token: UUID, backend: any AgentBackend) async throws {
        let id = "\(sessionNamespace)agentapp_setup_\(UUID().uuidString.lowercased())"
        turns.sessions[token] = id
        // Legacy servers take any id in X-Hermes-Session-Id; only native sessions are created (and deleted).
        guard try await backend.sessionTransport() == .nativeSessions else { return }
        let target = connection(of: bot)
        await cleanSetupSessions(on: target, backend: backend)
        defaults.set((defaults.stringArray(forKey: setupCleanupKey(target)) ?? []) + [id], forKey: setupCleanupKey(target))
        turns.sessions[token] = try await backend.createSession(title: "", systemPrompt: bot.outboundPersona, id: id)
    }

    /// Ends the attempt's session: deleted unless the box may still be running it (`keep`), then it goes at the next setup.
    func closeSetupSession(token: UUID, bot: Bot, keep: Bool, backend: any AgentBackend) async {
        guard turns.sessions.removeValue(forKey: token) != nil, !keep else { return }
        let target = connection(of: bot)
        // A cancelled turn must not cancel its cleanup.
        await Task { await self.cleanSetupSessions(on: target, backend: backend) }.value
    }

    func cleanSetupSessions(on target: String, backend: any AgentBackend) async {
        guard let hermes = backend as? HermesBackend else { return }
        let live = Set(turns.sessions.values)
        for id in defaults.stringArray(forKey: setupCleanupKey(target)) ?? [] where !live.contains(id) {
            guard id.range(of: #"\A[A-Za-z0-9_-]*agentapp_setup_[a-f0-9-]+\z"#, options: .regularExpression) != nil else { continue }
            if (try? await hermes.deleteUpdaterSession(id)) != nil {
                defaults.set((defaults.stringArray(forKey: setupCleanupKey(target)) ?? []).filter { $0 != id }, forKey: setupCleanupKey(target))
            }
        }
    }

    private func setupCleanupKey(_ target: String) -> String { "setup.sessions.cleanup." + target }

    /// The wait before another attempt of a setup turn that did not reach the box (or found it briefly unable); nil = no retry.
    func setupRetryDelay(after end: TurnEnd, failures: Int) -> Duration? {
        guard failures < Self.setupRetryDelays.count, case .error(let error) = end, Self.isTransient(error) else { return nil }
        return Self.setupRetryDelays[failures]
    }

    static func isTransient(_ error: Error) -> Bool {
        if let broken = error as? StreamBreak { return !broken.delivered && isTransient(broken.underlying) }
        if let url = error as? URLError { return TurnOutcome.certainlyUnsentCodes.contains(url.code) || url.code == .timedOut || url.code == .networkConnectionLost }
        if case BackendError.http(let code, _) = error { return [429, 502, 503, 504].contains(code) }
        return false
    }

    /// The row goes back to streaming for the next attempt, empty, with `status` until text arrives.
    func resetForResend(_ assistant: ChatMessage, status: String) {
        assistant.content = ""; assistant.activity = nil; assistant.lastTextAt = nil
        assistant.turnState = .incomplete; assistant.isStreaming = true
        [TurnKey.run, TurnKey.why, TurnKey.ambiguous, TurnKey.toolTokens].forEach { assistant.metadata[$0] = nil }
        assistant.metadata["status"] = status
        objectWillChange.send()
    }

    // MARK: Context overflow

    /// The reply row holds only the box's failure copy (Hermes streams it as the answer of a failed turn).
    static func isFailureCopy(_ content: String, of text: String) -> Bool {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = ContextOverflow.untagged(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, ContextOverflow.matches(content) else { return false }
        return text.hasPrefix(content.prefix(60)) || content.hasPrefix(text.prefix(60))
    }

    /// After a turn the model could not fit: first the same session once more (Hermes compacts it as the turn starts, as
    /// /compress would), then a new session with the message resent. A turn whose steps already ran is never resent.
    /// nil = nothing to recover (or nothing more to try): the turn ends as it is.
    func recoverContext(after end: TurnEnd, step: ContextRecovery.Step, bot: Bot, conversation: any Conversation, assistant: ChatMessage,
                        backend: any AgentBackend, token: UUID) async -> ContextRecovery.Action? {
        guard step != .newSession, ContextOverflow.isOverflow(end), isCurrent(token), !Task.isCancelled, bot.backend == .hermes,
              !(conversation is GroupChat), !isTeamThread(conversation), !isWorkflowThread(conversation),
              turns.parts[assistant.id] == nil, turns.steers[assistant.id] == nil else { return nil }
        let ranSteps = (assistant.activity?.total ?? 0) > 0
        if step == .none, !ranSteps {
            resetForResend(assistant, status: TurnErrorCopy.compacting)
            return .resend(.compacted)
        }
        let user = conversation.messages.last { $0.role == .user && $0.createdAt <= assistant.createdAt }
        if !ranSteps { resetForResend(assistant, status: TurnErrorCopy.startingNew) }
        do { try await continueInNewSession(bot: bot, conversation: conversation, before: user ?? assistant, backend: backend, resent: !ranSteps) }
        catch { return nil }
        return ranSteps ? .stop(TurnErrorCopy.stoppedTooLong) : .resend(.newSession)
    }

    /// The chat's next turns go to a new, empty session; its transcript stays. The line saying so is the history boundary.
    func continueInNewSession(bot: Bot, conversation: any Conversation, before row: ChatMessage, backend: any AgentBackend, resent: Bool) async throws {
        let base = conversation === bot ? "agentapp_\(bot.id.uuidString.lowercased())" : "agentapp_thread_\(conversation.id.uuidString.lowercased())"
        let id = "\(sessionNamespace)\(base)_\(UUID().uuidString.lowercased().prefix(8))"
        if try await backend.sessionTransport() == .nativeSessions {
            let note = { [unowned self] (text: String) in insertNote(text, in: conversation, before: row) }
            let plan = try await prepareModel(for: bot, backend: backend, note: note)
            let created = try await backend.createSession(title: "", systemPrompt: bot.outboundPersona, id: id)
            if let plan { try await applyModel(plan, bot: bot, sessionID: created, record: conversation === bot, note: note) }
            conversation.hermesSessionID = created
        } else {
            conversation.hermesSessionID = id
        }
        let line = ChatMessage(role: .system, content: resent ? TurnErrorCopy.newSession : TurnErrorCopy.newSessionNotSent,
                               metadata: [ContextKey.boundary: "1"])
        conversation.messages.insert(line, at: conversation.messages.firstIndex { $0.id == row.id } ?? conversation.messages.endIndex)
        objectWillChange.send(); save()
    }
}
