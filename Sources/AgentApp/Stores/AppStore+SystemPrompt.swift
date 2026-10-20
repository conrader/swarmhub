import Foundation
import SwarmHubCore

extension AppStore {
    /// Render at backend selection, not bot creation: imported/decoded bots and existing
    /// sessions get current settings on their next turn without any persona migration.
    func defaultBotInstructions(for bot: Bot) throws -> String {
        let coordinator = orientationCoordinator(for: bot)
        let coordinatorAddress = coordinator.map {
            "\($0.name) (\($0.hermesProfile ?? $0.openClaw?.agentID ?? $0.name))"
        }
        let reviewerName: (UUID?) -> String = { id in
            id.flatMap { id in self.bots.first { $0.id == id }?.name } ?? "unavailable reviewer"
        }
        let routes = ApprovalRouter.candidates(bot: bot.effectiveRouting, global: globalApprovalRoutes)
            .map { "\(ApprovalRouter.scopeLabel($0.scope)): \($0.route.label(reviewerName: reviewerName))" }
        return try BotSystemPrompt.render(BotPromptContext(
            name: bot.name, role: bot.botDescription.isEmpty ? bot.title : bot.botDescription,
            owner: userName, coordinator: coordinatorAddress, timeZone: heartbeatTimeZone.identifier,
            approvalRules: routes, quietHours: quietHours.label))
    }
}
