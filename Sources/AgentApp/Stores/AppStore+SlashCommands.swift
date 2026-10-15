import Foundation

/// P45 1: what Send does with the composer's text in a bot chat: run a `/` command, warn and send an unknown `/x` as
/// text, or send a plain message. Command lines are local `.system` rows (never sent to the bot).
enum SlashKey {
    /// A command's own line ("1"); the transcript draws it with the command icon.
    static let line = "slash"
}

extension AppStore {
    /// The composer's Send in a 1:1 chat (or one of its threads). True when the draft should be cleared.
    @discardableResult func submitComposer(text: String, attachments: [ChatAttachment] = []) -> Bool {
        guard let bot = selectedBot else { return false }
        let conversation = currentConversation(of: bot)
        switch SlashInput(text) {
        case .message: return sendMessageOrHandOff(text, attachments: attachments, bot: bot)
        case .unknown:
            // The warning goes above the message it explains; it is removed again when the message cannot be sent.
            let warning = ChatMessage(role: .system, content: SlashInput.unknownWarning, metadata: [TurnKey.tone: "warning"])
            conversation.messages.append(warning)
            guard send(text: text, attachments: attachments) else { conversation.messages.removeAll { $0.id == warning.id }; return false }
            return true
        case .command(let command, let arguments):
            return run(command, arguments: arguments, bot: bot, conversation: conversation)
        }
    }

    func run(_ command: SlashCommand, arguments: String, bot: Bot, conversation: any Conversation) -> Bool {
        switch command {
        case .help: commandLine(SlashMenu.helpText(), in: conversation)
        case .new: newThreadCommand(bot: bot)
        case .model: modelCommand(arguments, bot: bot, in: conversation)
        case .stop: stopCommand(in: conversation)
        case .retry: retryCommand(bot: bot, in: conversation)
        case .status: commandLine(statusText(bot: bot, conversation: conversation), in: conversation)
        case .goal, .subgoal, .loop, .heartbeat: return automationCommand(command, arguments: arguments, bot: bot, conversation: conversation)
        }
        return true
    }

    /// A local line in the chat; `chatHistory` leaves it out, so the bot never sees it.
    func commandLine(_ text: String, in conversation: any Conversation) {
        conversation.messages.append(ChatMessage(role: .system, content: text, metadata: [SlashKey.line: "1"]))
        objectWillChange.send(); save()
    }

    // MARK: Commands

    /// `/new`: a new thread from the chat's last reply (the app's Reply in thread).
    private func newThreadCommand(bot: Bot) {
        guard let last = bot.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }), canFork(bot) else {
            commandLine("A new thread needs a reply to start from, on a server that can fork chats.", in: bot); return
        }
        replyInThread(to: last, in: bot)
    }

    /// `/model <name>`: the existing model switch (`switchModel`), for the one model whose name matches.
    private func modelCommand(_ name: String, bot: Bot, in conversation: any Conversation) {
        let picker = modelPicker(for: bot)
        let current = currentModel(for: bot).map { "Model: \($0.model)\($0.provider.map { " (\($0))" } ?? "")" } ?? "Model: not known yet"
        guard !name.isEmpty else { commandLine(current + ". Type /model <name> to switch.", in: conversation); return }
        let items = picker.groups.flatMap(\.items).filter { $0.disabledReason == nil }
        let wanted = name.lowercased()
        let exact = items.filter { $0.model.lowercased() == wanted || "\($0.supplierSlug)/\($0.model)".lowercased() == wanted }
        let matches = exact.isEmpty ? items.filter { $0.model.lowercased().contains(wanted) } : exact
        guard bot.hermesSessionID != nil else { commandLine("Send a message first; the model is set per chat session.", in: conversation); return }
        guard matches.count == 1, let item = matches.first else {
            let names = matches.prefix(6).map(\.model).joined(separator: ", ")
            commandLine(matches.isEmpty ? "No model named \(name) on this bot's list. \(current)." : "Several models match \(name): \(names). Type the full name.", in: conversation)
            return
        }
        commandLine("Switching to \(item.model)…", in: conversation)
        Task { await switchModel(for: bot, provider: item.supplierSlug, model: item.model) }
    }

    /// `/stop`: the running reply and, from item 2 on, the chat's goal and loop.
    private func stopCommand(in conversation: any Conversation) {
        let stoppedAutomation = stopAutomations(in: conversation)
        if !isIdle(conversation) { stop(conversation) }
        else if !stoppedAutomation { commandLine("Nothing is running in this chat.", in: conversation) }
    }

    /// `/retry`: P16 Retry on a reply that was not sent; otherwise the last message again, as a new turn.
    private func retryCommand(bot: Bot, in conversation: any Conversation) {
        if let row = conversation.messages.last(where: { $0.role == .assistant }), canRetry(row) { retry(row); return }
        guard isIdle(conversation) else { commandLine("Wait for the current reply, or /stop it first.", in: conversation); return }
        guard let last = conversation.messages.last(where: { $0.role == .user && !$0.isSteer }) else { commandLine("Nothing to retry yet.", in: conversation); return }
        _ = send(text: last.content, attachments: last.attachments, bot: bot, conversation: conversation, replyToID: nil, waitWhenFull: true)
    }

    /// `/status`: what the app knows now — model, tokens, context, and the chat's goal, loop and heartbeat.
    func statusText(bot: Bot, conversation: any Conversation) -> String {
        var lines: [String] = []
        if let model = currentModel(for: bot) { lines.append("Model: \(model.model)\(model.provider.map { " · \($0)" } ?? "") (\(model.source))") }
        else { lines.append("Model: not known yet (open the bot's Overview to read it)") }
        let session = conversation.hermesSessionID
        if let usage = botUsageCache[bot.id]?.report.sessions.first(where: { $0.id == session }) {
            lines.append("Tokens this chat: \(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out")
        } else { lines.append("Tokens: not read yet (Activity tab)") }
        let rows = conversation.messages.filter { $0.role != .system && !$0.content.isEmpty }
        let characters = rows.reduce(0) { $0 + $1.content.count }
        lines.append("Context: \(rows.count) messages, about \((characters / 4).formatted()) tokens")
        lines.append(isIdle(conversation) ? "Reply: idle" : "Reply: running")
        lines += automationStatusLines(for: conversation)
        return lines.joined(separator: "\n")
    }
}
