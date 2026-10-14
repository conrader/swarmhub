import Foundation

/// P27 D9: what a running bot is doing, for the sidebar.
extension AppStore {
    /// "Working: terminal · ls -la" for the bot whose reply is streaming and has had no new text for a minute (counted
    /// from its start when no text came yet) while a step ran; nil otherwise.
    func workingLine(for bot: Bot, now date: Date? = nil) -> String? {
        guard streamingBotID == bot.id, let assistant = streamingAssistant, assistant.isStreaming else { return nil }
        return ActivityCopy.sidebarLine(assistant.activity, started: assistant.createdAt, lastText: assistant.lastTextAt, now: date ?? now())
    }
}
