import Foundation

/// P32 item 12: after the manager's model recipe (`manager-hermes.md`) finishes, the "Model:" lines of the bots on its
/// connection are read again (`includeSkills: false`, GETs only), so a model changed by chat does not stay stale.
/// P31 D: when the turn read the recipe's log (DONE), the manager also reports `models` in a quiet turn, so the
/// Sub-agents lines follow a sub-agent model change.
extension AppStore {
    nonisolated static let modelRecipeLog = "swarmhub-model.log"

    /// The recipe finished when a step of the turn read its log (the recipe ends by `cat`-ing it) or the reply carries
    /// a `swarmhub` block.
    nonisolated static func modelRecipeFinished(reply: String, steps: [ToolStep]) -> Bool {
        reply.contains("```swarmhub") || modelLogRead(steps)
    }

    /// A step of the turn read the recipe's log: the recipe ran to DONE.
    nonisolated static func modelLogRead(_ steps: [ToolStep]) -> Bool { steps.contains { $0.preview?.contains(modelRecipeLog) == true } }

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
        let steps = turnSteps(endingAt: reply, in: conversation)
        guard isManager(manager), manager.backend == .hermes, conversation === manager,
              Self.modelRecipeFinished(reply: reply.content, steps: steps) else { return [] }
        let target = connection(of: manager)
        let reported = SwarmhubBlock.ops(in: reply.content)?.contains { if case .models = $0 { true } else { false } } == true
        let readsModels = Self.modelLogRead(steps) && !reported
        let affected = bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly && connection(of: $0) == target }
        let ids = affected.map(\.id)
        Task {
            for id in ids {
                guard let bot = bots.first(where: { $0.id == id }) else { continue }
                await loadServerInfo(for: bot, force: true, includeSkills: false)
            }
            if readsModels { await checkModels(on: target) }
        }
        return affected
    }
}
