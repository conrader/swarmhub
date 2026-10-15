import Foundation

/// The live reply's phase for bot, thread and group sidebar rows.
extension AppStore {
    func workingLine(for bot: Bot, now date: Date? = nil) -> String? {
        guard streamingBotID == bot.id else { return nil }
        return currentActivityLine(at: date ?? now())
    }

    func workingLine(for group: GroupChat, now date: Date? = nil) -> String? {
        guard isStreaming, streamingConversation === group else { return nil }
        return currentActivityLine(at: date ?? now())
    }

    private func currentActivityLine(at date: Date) -> String? {
        guard let assistant = streamingAssistant, assistant.isStreaming else { return nil }
        return ActivityCopy.sidebarLine(assistant.activity, lastText: assistant.lastTextAt, now: date)
    }
}
