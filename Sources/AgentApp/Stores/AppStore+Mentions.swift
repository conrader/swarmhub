import Foundation

/// Leading @mentions are routed by SwarmHub into task-specific ordinary API sessions.
/// Nothing is installed on the server. Legacy bot-message histories remain readable.
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


}

extension AppStore {
    /// Connected Hermes peers on the same connection, excluding the sender. Work-together groups may span connections.
    func mentionTargets(for bot: Bot) -> [Bot] {
        guard bot.backend == .hermes, !bot.isReadOnlyArchive else { return [] }
        let target = connection(of: bot)
        return bots.filter { $0.id != bot.id && $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isHidden && $0.hermesProfile != nil && connection(of: $0) == target }
    }

    /// The bot still needs swarmhub-messages (or an older version than this build ships).
    func lacksMessagingSkill(_ bot: Bot) -> Bool { missingMessagingSkills(for: bot).contains { $0.name == "swarmhub-messages" } }

    /// Duplicate display names require the stable suffix shown by the picker.
    func mentionLabel(_ target: Bot) -> String {
        bots.filter { $0.name.caseInsensitiveCompare(target.name) == .orderedSame }.count > 1
            ? target.name + "#" + target.id.uuidString.prefix(8) : target.name
    }
    enum MentionSend: Equatable { case none, team(botID: UUID, text: String), ambiguous }

    func mentionSend(_ text: String, in bot: Bot) -> MentionSend {
        let targets = mentionTargets(for: bot)
        if let found = MentionHandOff.parse(text, names: targets.map(mentionLabel)),
           let target = targets.first(where: { mentionLabel($0) == found.name }) { return .team(botID: target.id, text: found.text) }
        if let found = MentionHandOff.parse(text, names: targets.map(\.name)),
           targets.filter({ $0.name.caseInsensitiveCompare(found.name) == .orderedSame }).count > 1 { return .ambiguous }
        return .none
    }

    func sendMessageOrHandOff(_ text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        switch mentionSend(text, in: bot) {
        case .none: return send(text: text, attachments: attachments)
        case .ambiguous:
            errorMessage = "More than one agent has that name. Choose the recipient with its identity suffix from the @ picker."; return false
        case .team(let id, let message):
            guard let recipient = bots.first(where: { $0.id == id }) else { return false }
            guard attachments.isEmpty else {
                errorMessage = "Open the recipient's chat to send attachments, or add a shared project fact. Team handoffs currently carry text only."; return false
            }
            mentionSkillOffer = nil
            return startTeamRequest(message, origin: currentConversation(of: bot), coordinator: bot, recipient: recipient,
                                    roster: [bot, recipient], display: text)
        }
    }
}
