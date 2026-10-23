import Foundation

/// How a webhook panel call reaches the agent's profile: an injected runner (tests), a subprocess for Hermes on this
/// Mac (no model, like `ManagedLocalControl`), or one terminal call in a throwaway session on the box, the native
/// management-turn transport the box updater's status read uses. The command carries names and a key digest only.
extension AppStore {
    func runWebhookPanel(_ arguments: [String], for bot: Bot) async throws -> WebhookPanel {
        if let webhookControl { return try WebhookPanel.decode(try await webhookControl(bot, arguments)) }
        if webhooksAreLocal(bot) {
            return try await Self.localWebhookPanel(arguments, profile: bot.hermesProfile ?? "default",
                                                    home: managedHome ?? FileManager.default.homeDirectoryForCurrentUser)
        }
        return try await webhookBoxTurn(arguments, for: bot)
    }

    nonisolated static func localWebhookPanel(_ arguments: [String], profile: String, home: URL) async throws -> WebhookPanel {
        do { return try WebhookPanel.decode(try await localSwarmctl(arguments, profile: profile, home: home)) }
        catch LocalSwarmctlError.missing { throw WebhookPanelError.unavailable(WebhookCopy.skillMissing) }
        catch LocalSwarmctlError.failed(let problem, let exit) { throw WebhookPanelError.refusal(problem, exit: exit) }
    }

    /// The agent that manages the box runs the call (else the agent itself), in a session that is deleted afterwards.
    func webhookBoxTurn(_ arguments: [String], for bot: Bot) async throws -> WebhookPanel {
        try await swarmctlBoxTurn(arguments, for: bot, as: WebhookPanelCall.self, kind: "webhooks", request: WebhookCopy.turnRequest,
                                  nativeSessions: WebhookCopy.nativeSessions).panel()
    }
}

extension WebhookPanelCall: BoxCommandCall {
    var answered: Bool { outcome != nil }
}
