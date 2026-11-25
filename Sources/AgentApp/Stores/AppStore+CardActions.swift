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

    /// Only ordinary binary questions stay open in history. A reply linked to a message
    /// with several cards needs a block key to identify which one it answered.
    func choiceStatus(_ source: ChatMessage, target: ConversationActionTarget, key: String,
                      binary: Bool) -> (picked: String?, enabled: Bool) {
        let picked = source.metadata[key]
        guard picked == nil, let (bot, conversation) = actionConversation(target),
              storeRestoreOffer == nil, !bot.isReadOnlyArchive, source.role == .assistant,
              !source.isStreaming, source.turnState == nil || source.turnState == .finished,
              !(conversation is GroupChat) || source.authorID == bot.id,
              let index = conversation.messages.lastIndex(where: { $0 === source }) else { return (picked, false) }

        let later = conversation.messages.suffix(from: index + 1)
        guard binary || !later.contains(where: { !$0.isSilent }) else { return (nil, false) }
        for reply in later where reply.role == .user && reply.replyToID == source.id {
            if let answeredKey = reply.metadata[ChoiceReply.cardKey] {
                if answeredKey == key { return (reply.content, false) }
            } else if binary, !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Older stores and composer replies link to the row, not a particular block.
                let cards = ChatCardParser.parseVisibleReply(source.content).filter {
                    switch $0 {
                    case .choices, .multiChoices, .draft: true
                    default: false
                    }
                }
                if cards.count <= 1 { return (reply.content, false) }
            }
        }
        return (nil, isIdle(conversation))
    }

    /// A card action uses the target captured by its view, independent of the current chat selection.
    @discardableResult func performCardAction(target: ConversationActionTarget, sourceID: UUID, index: Int, expected: ChatBlock,
                                              choice: ChatChoiceAnswer? = nil, editedDraft: DraftCard? = nil, shownContent: String? = nil) -> Bool {
        guard let (bot, conversation) = actionConversation(target),
              let source = conversation.messages.first(where: { $0.id == sourceID }),
              source.role == .assistant, !source.isStreaming else { return false }
        if case .group = target, source.authorID != bot.id { return false }
        let blocks = ChatCardParser.parseVisibleReply(source.content)
        guard shownContent == nil || shownContent == source.content, blocks.indices.contains(index), blocks[index] == expected else {
            presentError("This card changed. Review the current version before answering it.", reason: .card, bot: bot); return false
        }
        var question: String?
        let queueChoice: Bool
        let key: String, text: String, value: String
        switch expected {
        case .choices(let prompt, let options):
            let binary = ChoiceReply.isYesNo(options)
            guard choiceStatus(source, target: target, key: "picked.\(index)", binary: binary).enabled,
                  let reply = choice?.text(options: options) else { return false }
            if binary {
                // A marker-style card puts its question in the prose before the options.
                if !prompt.isEmpty { question = prompt }
                else if case .markdown(let prose)? = blocks[..<index].last { question = prose }
                else { question = "Choice \(index + 1) (\(options.joined(separator: " / ")))" }
            }
            queueChoice = true
            key = "picked.\(index)"; text = reply; value = reply
        case .multiChoices(_, let options):
            guard choiceStatus(source, target: target, key: "picked.\(index)", binary: false).enabled,
                  let reply = choice?.multipleText(options: options) else { return false }
            queueChoice = true
            key = "picked.\(index)"; text = reply; value = reply
        case .draft(let original):
            queueChoice = false
            key = "draftSent.\(index)"
            if let editedDraft, editedDraft != original {
                // JSON preserves the exact field values, including line breaks and whitespace in the body.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                guard let data = try? encoder.encode(editedDraft) else { return false }
                text = "Send this edited draft:\n" + String(decoding: data, as: UTF8.self)
                value = "edited"
            } else {
                text = "Send it"
                value = "1"
            }
        default: return false
        }
        return sendCardReply(text, bot: bot, in: conversation, source: source, key: key, value: value, queueChoice: queueChoice, question: question)
    }

    @discardableResult func answerInferredChoice(target: ConversationActionTarget, source: ChatMessage, shownContent: String, answer: ChatChoiceAnswer) -> Bool {
        guard source.content == shownContent, let options = ChatChoiceInference.options(in: shownContent),
              let (bot, conversation) = actionConversation(target),
              let reply = answer.text(options: options.map(\.reply)) else { return false }
        let binary = ChoiceReply.isYesNo(options.map(\.label))
        let key = ChatChoiceInference.answerKey
        guard choiceStatus(source, target: target, key: key, binary: binary).enabled else { return false }
        return sendCardReply(reply, bot: bot, in: conversation, source: source, key: key, value: reply,
                             queueChoice: true, question: binary ? SwarmhubBlock.visibleText(shownContent) : nil)
    }

    private func sendCardReply(_ text: String, bot: Bot, in conversation: any Conversation, source: ChatMessage,
                               key: String, value: String, queueChoice: Bool, question: String?) -> Bool {
        guard source.metadata[key] == nil else { return false }
        var metadata = queueChoice ? [ChoiceReply.cardKey: key] : [:]
        if let question, conversation.messages.last(where: { !$0.isSilent }) !== source {
            let excerpt = question.trimmingCharacters(in: .whitespacesAndNewlines)
            let quote = excerpt.count > 1200 ? "…" + String(excerpt.suffix(1200)) : excerpt
            metadata[ChoiceReply.quoteKey] = "\(bot.name): \(quote)"
        }
        let accepted = if let group = conversation as? GroupChat {
            send(text: text, to: group, recipientIDs: [bot.id], sourceMessageID: source.id, queueChoice: queueChoice, metadata: metadata)
        } else {
            send(text: text, bot: bot, conversation: conversation, replyToID: source.id, waitWhenFull: queueChoice, metadata: metadata)
        }
        if accepted { source.metadata[key] = value; save() }
        return accepted
    }
}
