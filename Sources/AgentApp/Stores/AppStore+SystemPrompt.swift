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
        let local = BotPromptContext(
            name: bot.name, role: bot.botDescription.isEmpty ? bot.title : bot.botDescription,
            owner: userName, coordinator: coordinatorAddress, timeZone: heartbeatTimeZone.identifier,
            approvalRules: routes, quietHours: quietHours.label)
        // Only Hermes profiles have a cross-device identity. Keep OpenClaw's local context as before.
        guard bot.backend == .hermes else { return try BotSystemPrompt.render(local) }
        // Use mobile's HTTPS-only policy: even Mac loopback HTTP (the default) cannot be paired.
        guard let address = try? ConnectionAddress(
            bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL,
            profile: bot.hermesProfile ?? "default") else { return try BotSystemPrompt.render(local) }
        // Sync is optional. A load failure leaves the file untouched and chat uses local settings.
        guard let botPromptSync else { return try BotSystemPrompt.render(local) }
        let key = BotPromptDocument.botKey(address)
        do {
            try botPromptSync.observe(local, key: key, now: Int64(Date().timeIntervalSince1970 * 1_000))
        } catch {
            botPromptSyncWarning = "Bot prompt sync could not be saved. Chat is using local settings; the saved sync file was kept unchanged."
            return try BotSystemPrompt.render(local)
        }
        return try BotSystemPrompt.render(botPromptSync.context(for: key, fallback: local))
    }

    @discardableResult func syncBotPrompts(using transport: any BotPromptSyncTransport) async throws -> Bool {
        guard persistenceEnabled, let botPromptSync else { throw CoreError.storage }
        return try await botPromptSync.synchronize(using: transport)
    }
}
