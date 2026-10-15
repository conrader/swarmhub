import Foundation

/// The live reply's phase for bot, thread and group sidebar rows.
extension AppStore {
    /// P39: the bot's own chat or thread first, else a group turn it answers in.
    func workingLine(for bot: Bot, now date: Date? = nil) -> String? {
        let mine = runningTurns.values.filter { $0.botID == bot.id }
        guard let turn = mine.first(where: { !($0.conversation is GroupChat) }) ?? mine.first else { return nil }
        return activityLine(turn, at: date ?? now())
    }

    func workingLine(for group: GroupChat, now date: Date? = nil) -> String? {
        guard let turn = turn(in: group), !turn.stopping else { return nil }
        return activityLine(turn, at: date ?? now())
    }

    private func activityLine(_ turn: ConversationTurn, at date: Date) -> String? {
        guard let assistant = turn.assistant, assistant.isStreaming else { return nil }
        return ActivityCopy.sidebarLine(assistant.activity, lastText: assistant.lastTextAt, now: date)
    }
}
