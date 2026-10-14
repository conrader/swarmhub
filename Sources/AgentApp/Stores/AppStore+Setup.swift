import Foundation
import SwiftUI

/// P21: the setup window's commit, the simple Settings page's connection line and Test, and the user's name.
extension AppStore {
    enum SetupCommitError: Error, Equatable { case nothingChosen, moveNotConfirmed, notTested, saveFailed }

    /// D6: shown in group headers, Members and the group context; never stored in transcripts.
    var userName: String { UserIdentity.name(defaults: defaults) }

    /// From the settings and key attributes only (no decrypt, so it never prompts).
    var boxConfigured: Bool { FirstRun.boxConfigured(defaults: defaults, keyStore: keyStore) }

    /// The bots under the sidebar's "Hidden chats": sample bots stop being listed once a box is configured (P21 item 15).
    var hiddenChatBots: [Bot] { let configured = boxConfigured; return bots.filter { $0.isHidden && !($0.isDemo && configured) } }

    /// Agents that talk to a box (not samples, archives or the local mock).
    var connectedAgents: [Bot] { bots.filter { $0.backend == .hermes && !$0.isDemo && !$0.isReadOnlyArchive } }

    /// The simple page's status line, from attributes only: no network on open.
    var connectionStatusLine: String {
        guard boxConfigured || !connectedAgents.isEmpty else { return SimpleCopy.notConnected }
        let url = BoxAddress.url(defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL)
        return SimpleCopy.connected(to: url.map(BoxAddress.place) ?? SetupCopy.thisMac, agents: connectedAgents.count)
    }

    var anyKeyNeedsReentry: Bool { connectedAgents.contains { keyNeedsReentry($0) } }

    /// "Look around with sample agents" (D3): the old demo bots, labelled as samples, hidden once a box is connected.
    func loadSamples() {
        guard !bots.contains(where: \.isDemo) else { bots.filter(\.isDemo).forEach { $0.isHidden = false }; selectVisibleChat(); save(); return }
        let real = bots
        loadDemoData()
        bots += real
        selectVisibleChat(); save()
    }

    /// The setup window opens prefilled: the saved address on a configured app (D7), plus a history-only agent's line.
    func setupPrefill(for bot: Bot? = nil) -> SetupPrefill {
        let saved = defaults.string(forKey: "hermesBaseURL")
        let name = bot.flatMap { $0.hermesProfile ?? GrokNaming.profile(forName: $0.name) }
        return SetupPrefill(address: saved, agentName: name, startAtAddress: saved != nil || bot != nil)
    }

    /// Opens the setup window (its own scene) prefilled for this app's state, or with `prefill`.
    func openSetup(_ prefill: SetupPrefill? = nil, openWindow: OpenWindowAction) {
        setupPrefill = prefill ?? setupPrefill(); setupGeneration += 1
        openWindow(id: SetupView.windowID)
    }

    /// Probe ids already bound to a bot on this app (shown "Already added" on S4).
    var addedProfileIDs: Set<String> { Set(bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive }.map { $0.hermesProfile ?? "default" }) }

    /// Appends one bot per available probe without a bot yet; shared by discovery and the setup commit.
    @discardableResult func appendAgents(from probes: [HermesProfileProbe], only names: Set<String>? = nil) -> [Bot] {
        var added: [Bot] = []
        for probe in probes {
            guard case .available(let profile) = probe.status, names?.contains(profile.id) ?? true else { continue }
            guard !bots.contains(where: { $0.backend == .hermes && ($0.hermesProfile ?? "default") == profile.id }) else { continue }
            let bot = Bot(name: profile.name, title: "Hermes profile", description: "Hermes profile: \(profile.id)", backend: .hermes, hermesProfile: profile.id)
            bots.append(bot); added.append(bot)
        }
        return added
    }

    /// S4's Add (P21 item 14): one synchronous block with no network call. Writes the address, the keys and the ticked
    /// agents, hides sample bots, selects the first added agent and marks setup done; restores everything if a step
    /// fails. Idempotent. Changing a saved address needs `confirmMove` (D7).
    @discardableResult func commitSetup(_ result: SetupCheckResult, key: String, chosen: Set<String>, confirmMove: Bool) throws -> [Bot] {
        guard result.succeeded, let baseURL = result.baseURL else { throw SetupCommitError.notTested }
        guard !chosen.isEmpty else { throw SetupCommitError.nothingChosen }
        let savedAddress = defaults.string(forKey: "hermesBaseURL")
        if let savedAddress, BoxAddress.normalize(savedAddress) != baseURL.absoluteString, !confirmMove { throw SetupCommitError.moveNotConfirmed }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = result.extraKeys.filter { chosen.contains($0.key) }
        let accounts = (trimmedKey.isEmpty ? [] : ["hermes"]) + extra.keys.map { Self.keyAccount(forProfile: $0) }
        let oldKeys = Dictionary(accounts.map { ($0, keyStore.key(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let oldProfiles = defaults.object(forKey: "hermesProfiles"), oldState = defaults.object(forKey: FirstRun.stateKey)
        let oldBots = bots, oldBindings = bots.map { ($0, $0.hermesProfile) }, oldHidden = bots.map { ($0, $0.isHidden) }
        let oldSelection = (selectedBot, selectedGroup)
        do {
            defaults.set(baseURL.absoluteString, forKey: "hermesBaseURL")
            if !trimmedKey.isEmpty { keyStore.setKey(trimmedKey, for: "hermes") }
            for (profile, value) in extra { keyStore.setKey(value, for: Self.keyAccount(forProfile: profile)) }
            namedHermesProfiles += extra.keys.sorted()
            for profile in extra.keys { prefixIgnoredHermesProfiles.remove(profile) }
            bindUnboundGrokBots()
            let added = appendAgents(from: result.probes, only: chosen)
            bots.filter(\.isDemo).forEach { $0.isHidden = true }
            let target = added.first { !$0.isHidden } ?? bots.first { !$0.isHidden && chosen.contains($0.hermesProfile ?? "default") && $0.backend == .hermes }
            if let target { selectedBot = target; selectedGroup = nil; rememberSelection(bot: target) } else { selectVisibleChat() }
            FirstRun.record(.done, in: defaults)
            objectWillChange.send()
            try saveThrowing()
            return added
        } catch {
            if let savedAddress { defaults.set(savedAddress, forKey: "hermesBaseURL") } else { defaults.removeObject(forKey: "hermesBaseURL") }
            for (account, value) in oldKeys { keyStore.setKey(value, for: account) }
            defaults.set(oldProfiles, forKey: "hermesProfiles"); defaults.set(oldState, forKey: FirstRun.stateKey)
            bots = oldBots
            for (bot, profile) in oldBindings { bot.hermesProfile = profile }
            for (bot, hidden) in oldHidden { bot.isHidden = hidden }
            (selectedBot, selectedGroup) = oldSelection
            objectWillChange.send()
            throw SetupCommitError.saveFailed
        }
    }

    /// The simple page's Test (D10): read-only. The box's health, then the `--check-bots` probe per agent. Never adds
    /// agents or writes settings. Returns plain lines.
    func testConnectionPlain() async -> [String] {
        guard let url = BoxAddress.url(defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL) else { return [SetupCopy.badAddress] }
        let key = keyStore.key(for: "hermes")
        guard HermesBackend.permitsAPIKey(key, at: url) else { return [SetupCopy.notEncrypted(port: url.port)] }
        do { _ = try await HermesBackend(baseURL: url, apiKey: key, session: hermesSession).testConnection() }
        catch { return [SetupCheck.message(SetupCheck.outcome(for: error))] }
        let agents = connectedAgents
        var failed: [String] = []
        for bot in agents {
            let check = await HeadlessCommands.checkBot(bot, store: self)
            if !check.ok { failed.append(bot.name) }
        }
        var lines = [SimpleCopy.tested(answered: agents.count - failed.count, of: agents.count)]
        if !failed.isEmpty { lines.append(SimpleCopy.agentsNotAnswering(failed)) }
        return lines
    }
}
