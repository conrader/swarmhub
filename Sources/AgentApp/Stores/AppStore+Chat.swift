import Foundation

/// P4 chat parity: steer, threaded replies (forks), attachments, tapbacks, manual unread, Media jumps.
extension AppStore {
    // MARK: Capabilities

    func refreshFeatures(for bot: Bot) {
        guard bot.backend == .hermes, !needsKey(bot), let activeBackend = try? backend(for: bot) else { return }
        Task { if let flags = try? await activeBackend.features() { botFeatures[bot.id] = flags } }
    }

    /// "Reply in thread" is offered only when the server reports `session_fork` and the chat has a session.
    func canFork(_ bot: Bot) -> Bool {
        bot.backend == .hermes && !bot.isReadOnlyArchive && bot.hermesSessionID != nil && botFeatures[bot.id]?.contains("session_fork") == true
    }

    // MARK: Steer

    /// Posts the text to the running turn and shows it as a steer bubble; a refusal marks it and says why.
    func steer(text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard steerAvailable, streamingBotID == bot.id, let conversation = streamingConversation, conversation === currentConversation(of: bot) else { return false }
        guard attachments.isEmpty else { errorMessage = "Attachments can’t be added to a running turn; send them after it finishes."; return false }
        guard !value.isEmpty, let activeBackend = try? backend(for: bot) else { return false }
        deliverSteer(value, into: conversation, sessionID: conversation.hermesSessionID ?? bot.id.uuidString, backend: activeBackend)
        return true
    }

    /// Shows the steer bubble and posts it; a refusal marks the bubble and says why.
    func deliverSteer(_ value: String, into conversation: any Conversation, sessionID: String, backend activeBackend: any AgentBackend) {
        let message = ChatMessage(role: .user, content: value, metadata: ["steer": "sent"])
        conversation.messages.append(message); objectWillChange.send(); save()
        Task {
            do { try await activeBackend.steer(sessionID: sessionID, text: value) }
            catch {
                message.metadata["steer"] = "failed"
                conversation.messages.append(ChatMessage(role: .system, content: "Steer not delivered: \(error.localizedDescription)"))
                objectWillChange.send(); save()
            }
        }
    }

    // MARK: Threads

    func openThread(in bot: Bot) -> ChatThread? { openThreadID.flatMap { id in bot.threads.first { $0.id == id } } }
    func currentConversation(of bot: Bot) -> any Conversation { openThread(in: bot) ?? bot }

    /// Opens the message's thread, forking the bot's session first when there is none yet.
    func replyInThread(to message: ChatMessage, in bot: Bot) {
        if let existing = bot.thread(for: message.id) { openThreadID = existing.id; return }
        guard canFork(bot), let sessionID = bot.hermesSessionID, !isStreaming else { return }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) } catch { errorMessage = error.localizedDescription; return }
        let threadID = UUID()
        Task {
            do {
                let forkID = try await activeBackend.forkSession(sessionID: sessionID, id: "agentapp_thread_\(threadID.uuidString.lowercased())")
                guard bot.thread(for: message.id) == nil else { return }
                bot.threads.append(ChatThread(id: threadID, parentMessageID: message.id, parentSessionID: sessionID, hermesSessionID: forkID))
                if selectedBot?.id == bot.id { openThreadID = threadID }
                objectWillChange.send(); save()
            } catch { errorMessage = "Could not start a thread: \(error.localizedDescription)" }
        }
    }

    func closeThread() { openThreadID = nil }

    // MARK: Attachments

    /// Prepares picked, dropped or pasted files; refusals are reported and skipped.
    func prepareAttachments(_ urls: [URL]) -> [ChatAttachment] {
        urls.compactMap { url in
            do { return try attachmentEncoder.prepare(fileURL: url) } catch { errorMessage = error.localizedDescription; return nil }
        }
    }

    func prepareAttachment(imageData: Data, name: String) -> ChatAttachment? {
        do { return try attachmentEncoder.prepare(imageData: imageData, name: name) } catch { errorMessage = error.localizedDescription; return nil }
    }

    func attachmentURL(_ attachment: ChatAttachment) -> URL? { attachmentEncoder.fileURL(for: attachment) }

    // MARK: Tapbacks, unread, navigation

    /// Adds or removes a tapback and saves it with the message (local only).
    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        if let index = message.reactions.firstIndex(of: emoji) { message.reactions.remove(at: index) } else { message.reactions.append(emoji) }
        objectWillChange.send(); save()
    }

    func markUnread(_ bot: Bot) { bot.manualUnread = true; objectWillChange.send(); save() }

    /// Selecting a chat clears both the automatic unread count and the manual flag.
    func open(_ bot: Bot) {
        if selectedBot?.id != bot.id { openThreadID = nil }
        selectedBot = bot; selectedGroup = nil
        if bot.unreadCount != 0 || bot.manualUnread { bot.unreadCount = 0; bot.manualUnread = false; save() }
        loadHermesHistory(for: bot)
    }

    /// Media tab → the message in the main chat or its thread.
    func jump(to item: MediaItem) {
        openThreadID = item.threadID
        scrollTarget = item.messageID
    }
}
