import Foundation

/// P25: the setup window's OpenClaw path. Test goes through the real hub (the same identity and pairing code as
/// Settings), so the Gateway entry and key are saved at Test: the one documented exception to "only Add writes". A
/// Gateway this run created is forgotten again on Cancel, Back to the software choice or closing the window; one that
/// existed before the run is never forgotten here.
extension AppStore {
    /// S3-OC's Test. A saved Gateway with the same address is used as saved (a typed key is written to it, as Edit →
    /// Save would); otherwise this run's Gateway is created or updated. Never returns the key.
    func testSetupGateway(_ draft: OpenClawDraft) async -> (outcome: OpenClawSetupOutcome, gatewayID: String?) {
        guard let candidate = draft.gateway(updating: nil) else { return (.failed(draft.problem ?? SetupCopy.failed), nil) }
        // This run's Gateway at another address starts over: its key and pairing belong to the old address.
        if let previous = gateway(id: setupCreatedGatewayID), previous.url != candidate.url { await abandonSetupGateway() }
        let created = gateway(id: setupCreatedGatewayID)
        let target: OpenClawGateway
        if let existing = openClawGateways.first(where: { $0.url == candidate.url && $0.id != created?.id }) {
            await abandonSetupGateway()
            if let key = draft.typedKey { GatewayCredentials(gateway: existing, keyStore: keyStore).setSharedToken(key) }
            target = existing
        } else {
            guard let updated = draft.gateway(updating: created) else { return (.failed(SetupCopy.failed), nil) }
            await saveGateway(updated, token: draft.typedKey)
            setupCreatedGatewayID = updated.id
            target = updated
        }
        // A link waiting for approval or failed starts a fresh attempt, so "Test again" really asks the Gateway again.
        if await !openClawHub.state(target.id).isConnected { await openClawHub.disconnect(target.id) }
        do {
            return (.connected(try await openClawHub.agents(for: target).agents), target.id)
        } catch {
            if case .pairingRequired(let requestId, _, _) = await openClawHub.state(target.id) { return (.pairingRequired(requestId: requestId), target.id) }
            let line = redactedOpenClaw(error, gateway: target)
            await openClawHub.disconnect(target.id) // no retry loop behind the window for a failed Test
            return (.failed(line), target.id)
        }
    }

    /// Cancel, Back to the software choice, closing the window or starting over: the Gateway this run created goes,
    /// with its three Keychain items.
    func abandonSetupGateway() async {
        guard let id = setupCreatedGatewayID else { return }
        setupCreatedGatewayID = nil
        if let gateway = gateway(id: id) { await forgetGateway(gateway) }
    }

    /// S4's Add for OpenClaw (D5): one bot per ticked agent through `appendOpenClawBots`, no network. Hides sample
    /// bots, selects the first added agent, marks setup done and keeps the Gateway. Restores the bots if saving fails.
    @discardableResult func commitSetupOpenClaw(gatewayID: String?, agents: [OpenClawAgent], chosen: Set<String>) throws -> [Bot] {
        guard let gatewayID, gateway(id: gatewayID) != nil else { throw SetupCommitError.notTested }
        guard !chosen.isEmpty else { throw SetupCommitError.nothingChosen }
        let oldBots = bots, oldHidden = bots.map { ($0, $0.isHidden) }, oldSelection = (selectedBot, selectedGroup)
        let oldState = defaults.object(forKey: FirstRun.stateKey)
        let added = appendOpenClawBots(agents, gatewayID: gatewayID, only: chosen).added
        bots.filter(\.isDemo).forEach { $0.isHidden = true }
        let target = added.first ?? bots.first { $0.openClaw?.gatewayID == gatewayID && chosen.contains($0.openClaw?.agentID ?? "") && !$0.isHidden }
        if let target { selectedBot = target; selectedGroup = nil; rememberSelection(bot: target) } else { selectVisibleChat() }
        FirstRun.record(.done, in: defaults)
        objectWillChange.send()
        do { try saveThrowing() } catch {
            bots = oldBots
            for (bot, hidden) in oldHidden { bot.isHidden = hidden }
            (selectedBot, selectedGroup) = oldSelection
            defaults.set(oldState, forKey: FirstRun.stateKey)
            objectWillChange.send()
            throw SetupCommitError.saveFailed
        }
        if setupCreatedGatewayID == gatewayID { setupCreatedGatewayID = nil }
        return added
    }
}
