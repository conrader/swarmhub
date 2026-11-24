import Foundation

/// Where a card's answer goes, captured when the card is rendered: a bot's chat, or a group with the member that
/// wrote the card. Changing the selection never changes it.
enum ConversationActionTarget: Hashable, Sendable {
    case bot(botID: UUID)
    case group(groupID: UUID, botID: UUID)
    var conversationID: UUID {
        switch self {
        case .bot(let botID): botID
        case .group(let groupID, _): groupID
        }
    }
}

extension AppStore {
    /// A card's target chat streams (its pick waits for that turn only).
    func isStreaming(for target: ConversationActionTarget) -> Bool { actionConversation(target).map { isStreaming(in: $0.1) } ?? false }

    /// The bot and conversation a target names, or nil once the bot or group (or the bot's membership) is gone.
    func actionConversation(_ target: ConversationActionTarget) -> (Bot, any Conversation)? {
        switch target {
        case .bot(let botID):
            return bots.first { $0.id == botID }.map { ($0, $0) }
        case .group(let groupID, let botID):
            guard let group = groups.first(where: { $0.id == groupID }), group.memberIDs.contains(botID),
                  let bot = bots.first(where: { $0.id == botID }) else { return nil }
            return (bot, group)
        }
    }

    /// Choices expire as soon as another visible message arrives or the chat starts another turn.
    func canAnswerChoice(_ source: ChatMessage, target: ConversationActionTarget) -> Bool {
        guard let (bot, conversation) = actionConversation(target) else { return false }
        return canAnswerChoice(source, bot: bot, in: conversation)
    }

    private func canAnswerChoice(_ source: ChatMessage, bot: Bot, in conversation: any Conversation) -> Bool {
        guard storeRestoreOffer == nil, !bot.isReadOnlyArchive, isIdle(conversation),
              source.role == .assistant, !source.isStreaming, source.turnState == nil || source.turnState == .finished,
              conversation.messages.last(where: { !$0.isSilent }) === source else { return false }
        return !(conversation is GroupChat) || source.authorID == bot.id
    }

    /// A pick on a choices card, or Send on a draft card, of message `sourceID` in `target`. Refused when the card is
    /// not a finished reply, has changed since it was shown (`expected`), was already answered, or (in a group) was
    /// written by another member. Choices also expire after a newer message. A group answer goes to the card's author
    /// only, as a reply to the card. Send on a draft tells the bot "Send it": the bot does the sending.
    @discardableResult func performCardAction(target: ConversationActionTarget, sourceID: UUID, index: Int, expected: ChatBlock, choice: ChatChoiceAnswer? = nil) -> Bool {
        guard let (bot, conversation) = actionConversation(target),
              let source = conversation.messages.first(where: { $0.id == sourceID }),
              source.role == .assistant, !source.isStreaming else { return false }
        if case .group = target, source.authorID != bot.id { return false }
        let blocks = ChatCardParser.parse(SwarmhubBlock.visibleText(source.content))
        guard blocks.indices.contains(index), blocks[index] == expected else {
            errorMessage = "This card changed. Review the current version before answering it."; return false
        }
        let key: String, text: String, value: String
        switch expected {
        case .choices(_, let options):
            guard canAnswerChoice(source, bot: bot, in: conversation), let reply = choice?.text(options: options) else { return false }
            key = "picked.\(index)"; text = reply; value = reply
        case .draft:
            key = "draftSent.\(index)"; value = "1"; text = "Send it"
        default: return false
        }
        return sendCardReply(text, bot: bot, in: conversation, source: source, key: key, value: value)
    }

    @discardableResult func answerInferredChoice(target: ConversationActionTarget, source: ChatMessage, expected: [ChatChoiceOption], answer: ChatChoiceAnswer) -> Bool {
        guard let (bot, conversation) = actionConversation(target), canAnswerChoice(source, bot: bot, in: conversation),
              ChatChoiceInference.options(in: source.content) == expected,
              let reply = answer.text(options: expected.map(\.reply)) else { return false }
        return sendCardReply(reply, bot: bot, in: conversation, source: source, key: ChatChoiceInference.answerKey, value: reply)
    }

    private func sendCardReply(_ text: String, bot: Bot, in conversation: any Conversation, source: ChatMessage, key: String, value: String) -> Bool {
        guard source.metadata[key] == nil else { return false }
        let accepted = if let group = conversation as? GroupChat {
            send(text: text, to: group, recipientIDs: [bot.id], sourceMessageID: source.id)
        } else {
            send(text: text, bot: bot, conversation: conversation, replyToID: source.id)
        }
        if accepted { source.metadata[key] = value; save() }
        return accepted
    }
}
