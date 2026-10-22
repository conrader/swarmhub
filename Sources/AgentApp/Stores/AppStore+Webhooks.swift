import Foundation

/// Webhook routines of a Hermes agent's profile, managed from the Routines tab. Each click is one `swarmctl webhook
/// panel` call (`AppStore+WebhookTransport.swift`) whose answer refreshes the list and the receiver state together.
extension AppStore {
    /// Hermes on this Mac runs the call as a subprocess, so the section may load itself; a box needs a model turn,
    /// which only a click starts.
    func webhooksAreLocal(_ bot: Bot) -> Bool {
        let address = bot.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
        return URL(string: address)?.host.map { ["localhost", "127.0.0.1", "::1"].contains($0) } ?? false
    }

    func canManageWebhooks(_ bot: Bot) -> Bool { bot.backend == .hermes && !bot.isReadOnlyArchive }

    func refreshWebhooks(for bot: Bot) async { _ = await performWebhook(.list, for: bot) }

    func startWebhookReceiver(for bot: Bot) async { _ = await performWebhook(.startReceiver, for: bot) }

    func deleteWebhook(_ webhook: BoxWebhook, for bot: Bot) async { _ = await performWebhook(.delete(webhook.routine), for: bot) }

    /// A new routine: the key is generated here and only its digest is sent; the answer's URL plus the key go to the
    /// one-time reveal (memory only, until its sheet closes) and nowhere else.
    @discardableResult func createWebhook(_ routine: String, for bot: Bot) async -> WebhookReveal? {
        await reveal(.create(routine), for: bot)
    }

    @discardableResult func rotateWebhookKey(_ webhook: BoxWebhook, for bot: Bot) async -> WebhookReveal? {
        await reveal(.rotate(webhook.routine), for: bot)
    }

    private func reveal(_ action: WebhookAction, for bot: Bot) async -> WebhookReveal? {
        let key = WebhookKey.generate()
        guard let panel = await performWebhook(action, for: bot, keyHash: WebhookKey.digest(key)),
              let routine = action.routine, let row = panel.webhooks.first(where: { $0.routine == routine }) else { return nil }
        let reveal = WebhookReveal(routine: routine, url: row.url, key: key, rotated: action == .rotate(routine))
        webhooks.update(bot.id) { $0.reveal = reveal }
        return reveal
    }

    /// The reveal sheet closed: the key is forgotten.
    func dismissWebhookReveal(for bot: Bot) { webhooks.update(bot.id) { $0.reveal = nil } }

    /// Runs one action; the state shows the box's answer or the reason it is missing. Nil when nothing was confirmed.
    @discardableResult func performWebhook(_ action: WebhookAction, for bot: Bot, keyHash: String? = nil) async -> WebhookPanel? {
        guard canManageWebhooks(bot), webhooks.state(for: bot.id).busy == nil else { return nil }
        guard let arguments = WebhookCommand.arguments(profile: bot.hermesProfile ?? "default", action: action, keyHash: keyHash) else {
            webhooks.update(bot.id) { $0.error = WebhookCopy.invalidName }
            return nil
        }
        webhooks.update(bot.id) { $0.busy = action; $0.error = nil; $0.notice = nil }
        do {
            let panel = try await runWebhookPanel(arguments, for: bot)
            webhooks.update(bot.id) { state in
                state.busy = nil; state.panel = panel
                state.notice = panel.result?.error.map { WebhookCopy.receiverRefused(ToolEvent.redacted($0)) }
            }
            return panel
        } catch {
            let reason = BotInfoCache.describe(error, secrets: keyHash.map { [$0] } ?? [])
            webhooks.update(bot.id) { $0.busy = nil; $0.error = reason }
            return nil
        }
    }
}
