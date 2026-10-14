import Foundation

/// P32 item 12: after the manager's model recipe (`manager-hermes.md`) finishes, the "Model:" lines of the bots on its
/// connection are read again (`includeSkills: false`, GETs only), so a model changed by chat does not stay stale.
extension AppStore {
    nonisolated static let modelRecipeLog = "swarmhub-model.log"

    /// The recipe finished when a step of the turn read its log (the recipe ends by `cat`-ing it) or the reply carries
    /// a `swarmhub` block.
    nonisolated static func modelRecipeFinished(reply: String, steps: [ToolStep]) -> Bool {
        reply.contains("```swarmhub") || steps.contains { $0.preview?.contains(modelRecipeLog) == true }
    }

    /// The steps of the turn that ended in `reply`: every reply row since the last message Konrad typed (a delivered
    /// steer splits one turn into several rows).
    func turnSteps(endingAt reply: ChatMessage, in conversation: any Conversation) -> [ToolStep] {
        guard let end = conversation.messages.firstIndex(where: { $0 === reply }) else { return reply.activity?.steps ?? [] }
        let start = conversation.messages[..<end].lastIndex { $0.role == .user && !$0.isSteer }.map { $0 + 1 } ?? 0
        return conversation.messages[start...end].filter { $0.role == .assistant }.flatMap { $0.activity?.steps ?? [] }
    }

    /// A finished reply in a Hermes manager's own chat: when the recipe finished, refreshes the bots on that connection.
    /// Returns the bots refreshed (empty when nothing triggered).
    @discardableResult func refreshModelsAfterRecipe(_ reply: ChatMessage, from manager: Bot, in conversation: any Conversation) -> [Bot] {
        guard isManager(manager), manager.backend == .hermes, conversation === manager,
              Self.modelRecipeFinished(reply: reply.content, steps: turnSteps(endingAt: reply, in: conversation)) else { return [] }
        let target = connection(of: manager)
        let affected = bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly && connection(of: $0) == target }
        let ids = affected.map(\.id)
        Task {
            for id in ids {
                guard let bot = bots.first(where: { $0.id == id }) else { continue }
                await loadServerInfo(for: bot, force: true, includeSkills: false)
            }
        }
        return affected
    }
}
