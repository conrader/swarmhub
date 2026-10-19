import Foundation

/// P38: where a card's answer goes, captured when the card is rendered: a bot's chat or thread, or a group with the
/// member that wrote the card. Changing the selection never changes it.
enum ConversationActionTarget: Hashable, Codable, Sendable {
    case bot(botID: UUID, threadID: UUID?)
    case group(groupID: UUID, botID: UUID)
    var conversationID: UUID {
        switch self {
        case .bot(let botID, let threadID): threadID ?? botID
        case .group(let groupID, _): groupID
        }
    }
}

extension AppStore {
    /// P39: a card's target chat streams (its pick waits for that turn only).
    func isStreaming(for target: ConversationActionTarget) -> Bool { actionConversation(target).map { isStreaming(in: $0.1) } ?? false }

    /// The bot and conversation a target names, or nil once the bot, thread or group (or the bot's membership) is gone.
    func actionConversation(_ target: ConversationActionTarget) -> (Bot, any Conversation)? {
        switch target {
        case .bot(let botID, let threadID):
            guard let bot = bots.first(where: { $0.id == botID }) else { return nil }
            guard let threadID else { return (bot, bot) }
            guard let thread = bot.threads.first(where: { $0.id == threadID }) else { return nil }
            return (bot, thread)
        case .group(let groupID, let botID):
            guard let group = groups.first(where: { $0.id == groupID }), group.memberIDs.contains(botID),
                  let bot = bots.first(where: { $0.id == botID }) else { return nil }
            return (bot, group)
        }
    }

    /// A pick on a choices card, or Send on a draft card, of message `sourceID` in `target`. Refused when the card is
    /// not a finished reply, has changed since it was shown (`expected`), was already answered, or (in a group) was
    /// written by another member. A group answer goes to the card's author only, as a reply to the card.
    /// P07 gap: Send binds the exact draft to a managed outbound record (`ManagedOutbound`) instead of posting
    /// "Send it"; the card's metadata keeps the record's intent. Outbound stays FAKE.
    @discardableResult func performCardAction(target: ConversationActionTarget, sourceID: UUID, index: Int, expected: ChatBlock, choice: String? = nil) -> Bool {
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
            guard let choice, options.contains(choice) else { return false }
            key = "picked.\(index)"; text = choice; value = choice
        case .draft(let draft):
            guard bot.backend == .hermes else {
                errorMessage = "Managed draft submission requires a Hermes profile with swarmhub-messages installed."; return false
            }
            let intent = ManagedOutbound.intent(sourceID: sourceID, index: index)
            key = "draftSent.\(index)"; value = intent
            text = ManagedOutbound.instruction(draft: draft, bot: bot.hermesProfile ?? "default", intent: intent)
        default: return false
        }
        guard source.metadata[key] == nil else { return false }
        let accepted = if let group = conversation as? GroupChat {
            send(text: text, to: group, recipientIDs: [bot.id], sourceMessageID: sourceID)
        } else {
            send(text: text, bot: bot, conversation: conversation, replyToID: sourceID)
        }
        if accepted { source.metadata[key] = value; save() }
        return accepted
    }
}
