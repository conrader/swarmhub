import Foundation

/// P41: what a bot-msg step shows on the sender's side: asking, the recipient's reply, or sent (queued, failed, or no
/// reply known).
enum BotMessageChipState: Equatable {
    case sent, asking, replied(String)
}

/// P41: bot-to-bot messages while they happen. The recipient works while a sender's bot-msg step runs (its sidebar row
/// and chat header say so), the sender's chip follows the step, and an arrival shows above a side thread too.
extension AppStore {
    /// A bot-msg step to `recipient` running now in another bot's live reply, with the sender's profile.
    func incomingBotMessage(to recipient: Bot) -> (sender: String, step: ToolStep)? {
        guard recipient.backend == .hermes else { return nil }
        let me = profile(of: recipient)
        for turn in runningTurns.values where !turn.stopping {
            guard let assistant = turn.assistant, assistant.isStreaming, let senderID = turn.botID, senderID != recipient.id,
                  let step = assistant.activity?.steps.last(where: { $0.isRunning && $0.botMessage?.to == me }), let call = step.botMessage
            else { continue }
            return (call.from ?? bots.first { $0.id == senderID }.map(profile(of:)) ?? "", step)
        }
        return nil
    }

    /// "Working… · message from Jarvis" while a sender waits on `recipient`; nil otherwise.
    func incomingBotMessageLine(for recipient: Bot) -> String? {
        incomingBotMessage(to: recipient).map { BotMessageCopy.incoming(from: displayName(forProfile: $0.sender)) }
    }

    /// The step's chip: asking while it runs in a streaming reply; once it ended, the reply from bot-msg's output, else
    /// the recipient's thread (its first line after the step started).
    func chipState(for step: ToolStep, key: BotThreadKey, streaming: Bool) -> BotMessageChipState {
        guard let call = step.botMessage else { return .sent }
        if ActivityCopy.isRunning(step, streaming: streaming) { return .asking }
        guard !call.noWait, !step.failed else { return .sent }
        if let reply = call.reply { return .replied(reply) }
        let fromThread = botMessages.loaded[key]?.first { $0.author == key.to && ($0.date ?? .distantPast) >= step.startedAt }
        return fromThread.map { .replied($0.text) } ?? .sent
    }

    /// The arrival lines to show above an open side thread of `bot`'s chat: those whose conversation is not opened yet.
    func arrivalsAboveThread(in bot: Bot) -> [ChatMessage] {
        guard openThread(in: bot) != nil, let unread = botMessages.unread[bot.id], !unread.isEmpty else { return [] }
        return bot.messages.filter { $0.presentation == .botMessage && unread.contains($0.metadata[BotMessageKey.session] ?? "") }
    }
}
