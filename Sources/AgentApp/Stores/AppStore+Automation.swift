import Foundation

/// P45 2–6: goal, loop, heartbeat and `@` hand-off hooks of the composer's commands.
extension AppStore {
    func automationCommand(_ command: SlashCommand, arguments: String, bot: Bot, conversation: any Conversation) -> Bool { false }
    /// Ends the chat's goal and loop (Stop); true when one was running.
    func stopAutomations(in conversation: any Conversation) -> Bool { false }
    func automationStatusLines(for conversation: any Conversation) -> [String] { [] }
    func mentionHandOff(_ text: String, in bot: Bot) -> String? { nil }
}
