import Foundation

/// P45 6: `@` in a 1:1 chat. "@Infra <text>" goes to the open bot with an instruction to hand it to Infra through
/// SwarmHub's bot-msg (the swarmhub-messages skill) and report back, so the exchange shows (P41/P42). A bot without the
/// skill gets the P42 offer "Install SwarmHub skills on all bots" first. Group chats keep their own routing.
enum MentionHandOff {
    /// The bot named by a leading `@Name` (longest name first, case-insensitive) and the text after it.
    static func parse(_ text: String, names: [String]) -> (name: String, text: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@") else { return nil }
        let rest = trimmed.dropFirst()
        for name in names.sorted(by: { $0.count > $1.count }) where rest.lowercased().hasPrefix(name.lowercased()) {
            let after = rest.dropFirst(name.count)
            guard after.isEmpty || after.first?.isWhitespace == true || after.first == "," || after.first == ":" else { continue }
            let body = after.drop { $0.isWhitespace || $0 == "," || $0 == ":" }.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (name, body)
        }
        return nil
    }

    static func message(_ text: String, to name: String, profile: String, from userName: String) -> String {
        """
        [SwarmHub hand-off] \(userName) asks you to pass this message to \(name) (Hermes profile `\(profile)`) with SwarmHub's bot-msg \
        (the swarmhub-messages skill), wait for the answer, and report back here what \(name) says. Don't answer it yourself.

        Message for \(name):
        \(text)
        """
    }
}

extension AppStore {
    /// The bots the open bot can reach with bot-msg: Hermes bots on its connection, itself excluded.
    func mentionTargets(for bot: Bot) -> [Bot] {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { return [] }
        let target = connection(of: bot)
        return bots.filter { $0.id != bot.id && $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isHidden && $0.hermesProfile != nil && connection(of: $0) == target }
    }

    /// The bot still needs swarmhub-messages (or an older version than this build ships).
    func lacksMessagingSkill(_ bot: Bot) -> Bool { missingMessagingSkills(for: bot).contains { $0.name == "swarmhub-messages" } }

    enum MentionSend: Equatable { case none, handOff(text: String, display: String), needsSkill }

    func mentionSend(_ text: String, in bot: Bot) -> MentionSend {
        let targets = mentionTargets(for: bot)
        guard let found = MentionHandOff.parse(text, names: targets.map(\.name)),
              let target = targets.first(where: { $0.name.caseInsensitiveCompare(found.name) == .orderedSame }), let profile = target.hermesProfile else { return .none }
        if lacksMessagingSkill(bot) { return .needsSkill }
        return .handOff(text: MentionHandOff.message(found.text, to: target.name, profile: profile, from: userName), display: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The composer's plain message in a 1:1 chat: a leading `@Bot` becomes the hand-off (shown as typed); a bot without
    /// the skill keeps the draft and shows the install offer.
    func sendMessageOrHandOff(_ text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        switch mentionSend(text, in: bot) {
        case .none: return send(text: text, attachments: attachments)
        case .needsSkill: mentionSkillOffer = bot.id; return false
        case .handOff(let message, let display):
            mentionSkillOffer = nil
            let conversation = currentConversation(of: bot)
            guard isIdle(conversation) else { return send(text: message, attachments: attachments) }
            guard send(text: message, attachments: attachments, bot: bot, conversation: conversation, replyToID: replyTo?.id, waitWhenFull: true,
                       metadata: [AutomationKey.display: display]) else { return false }
            replyTo = nil
            return true
        }
    }
}
