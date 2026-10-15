import Foundation

/// What one discovery found: how many profiles the box listed, the bots added at once (derived key answered), the ones
/// SwarmHub can connect, and the ones that need their own key.
struct BoxScan: Equatable { var listed = 0; var added: [String] = []; var adoptable: [String] = []; var needsKey: [String] = [] }

/// P35: connecting a box adds every bot on it. The connection's manager lists the box's profiles in a quiet turn (D1);
/// a profile answering with its P22 derived key is added at once (D2); the rest are connected in one confirmed batch
/// (D3, a visible turn in the manager's chat), undone per bot; `default` and typed-key profiles are never re-keyed
/// (D4); whatever is left shows under "On this box · not connected" (D5); sample bots go once a real bot exists (D6).
extension AppStore {
    static let typedKeyProfilesKey = "p35.typedKeyProfiles"
    static let samplesMigrationKey = "p35.samplesRemoved"

    /// Profiles whose key Konrad typed (setup window, pasted `profile=key`): never re-keyed.
    var typedKeyProfiles: Set<String> {
        get { Set((defaults.string(forKey: Self.typedKeyProfilesKey) ?? "").split(separator: ",").map(String.init)) }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: Self.typedKeyProfilesKey) }
    }

    /// Profiles bound to a Hermes bot on this connection.
    func boundProfiles(on target: String) -> Set<String> {
        Set(bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && connection(of: $0) == target }.map { $0.hermesProfile ?? "default" })
    }

    /// Hermes bots that talk to a box (no samples, archives, history-only or retired bots).
    private func connectedHermesBots() -> [Bot] {
        bots.filter { $0.backend == .hermes && !$0.isDemo && !$0.isReadOnlyArchive && !$0.isGrokHistoryOnly && !$0.retiredOnBox }
    }

    /// The manager on a connection; when there is none, the first connected Hermes bot with a key takes the role (D1).
    func ensureManager(on target: String) -> Bot? {
        let candidates = connectedHermesBots().filter { connection(of: $0) == target }
        if let manager = candidates.first(where: isManager) { return manager }
        guard let first = candidates.first(where: { !keyStore.key(for: Self.keyAccount(forProfile: $0.hermesProfile ?? "default")).isEmpty }) else { return nil }
        setCanManageBots(first, true)
        return first
    }

    // MARK: Discovery

    /// One turn the chat never shows: a fresh session, the instructions as management text, and the ops of the reply's
    /// swarmhub block. An approval request is declined (the recipes need none); nil when the turn did not finish.
    func quietBoxTurn(_ backend: any AgentBackend, persona: String, request: String, instructions: String) async -> [SwarmhubOp]? {
        let session = "\(sessionNamespace)agentapp_box_\(UUID().uuidString.lowercased())"
        do {
            if try await backend.sessionTransport() == .nativeSessions {
                _ = try await backend.createSession(title: "\(AppConstants.name): bots on this box", systemPrompt: persona, id: session)
            }
            let stream = try await backend.send(.init(sessionID: session, systemPrompt: persona, messages: [(role: "user", content: request)], managementText: instructions))
            var text = "", completed = false
            for try await event in stream {
                switch event {
                case .token(let value): text += value
                case .replace(let value): text = value
                case .approval(let approval): try? await backend.resolveApproval(approval, approved: false); return nil
                case .failed: return nil
                case .completed: completed = true
                default: break
                }
            }
            return completed || !text.isEmpty ? SwarmhubBlock.ops(in: text) : nil
        } catch { return nil }
    }

    /// The manager lists every profile of its box (quietly), then `absorbListed`. Nil when it could not.
    @discardableResult func discoverBox(manager: Bot) async -> BoxScan? {
        guard manager.backend == .hermes, let template = managerRecipeTemplate(.box),
              let instructions = BoxAdoption.listInstructions(template: template, managerProfile: manager.hermesProfile ?? "default"),
              let backend = try? backend(for: manager),
              let ops = await quietBoxTurn(backend, persona: manager.persona, request: "List every bot on this box for \(AppConstants.name).", instructions: instructions),
              let listed = ops.lazy.compactMap({ op -> [SwarmhubOp.ListedBot]? in if case .bots(let rows) = op { rows } else { nil } }).first else { return nil }
        return await absorbListed(listed, manager: manager)
    }

    /// Adds every listed profile that answers with its derived key (one try each, side by side) and lists the rest
    /// under the connection's "not connected" section. A failed adoption stays failed until retried.
    @discardableResult func absorbListed(_ listed: [SwarmhubOp.ListedBot], manager: Bot) async -> BoxScan {
        let target = connection(of: manager), profile = manager.hermesProfile ?? "default"
        let sorted = BoxAdoption.sort(listed, managerProfile: profile, typed: typedKeyProfiles, bound: boundProfiles(on: target))
        let tried = sorted.candidates.filter { $0.hasKey != false }.map(\.name)
        let managerKey = keyStore.key(for: Self.keyAccount(forProfile: profile))
        let address = manager.hermesBaseURL ?? defaults.string(forKey: "hermesBaseURL") ?? AppConstants.defaultHermesURL
        let probes = await withTaskGroup(of: (String, DerivedProbe).self) { group in
            for name in tried { group.addTask { (name, await self.probeDerived(name, managerKey: managerKey, baseURL: address, attempts: 1)) } }
            var found: [String: DerivedProbe] = [:]
            for await (name, probe) in group { found[name] = probe }
            return found
        }
        var scan = BoxScan(listed: listed.count, needsKey: sorted.needsKey.map(\.name))
        let previous = boxProfiles[target] ?? []
        var left = sorted.needsKey.map { BoxProfile(name: $0.name, hasKey: $0.hasKey ?? true, state: .needsKey) }
        for row in sorted.candidates {
            if case .reachable(let key)? = probes[row.name], boundBot(row.name, manager: manager) == nil {
                addConnectedBot(row.name, key: key, description: row.description, manager: manager, backup: nil); scan.added.append(row.name)
            } else {
                let state: BoxProfile.State = previous.first { $0.name == row.name }?.state == .failed ? .failed : .adoptable
                left.append(BoxProfile(name: row.name, hasKey: row.hasKey ?? true, state: state)); scan.adoptable.append(row.name)
            }
        }
        boxProfiles[target] = left.isEmpty ? nil : left
        if !scan.added.isEmpty { removeSampleBots() }
        objectWillChange.send(); save()
        return scan
    }

    /// Adds a bot for a profile whose derived key answered; `backup` is set when SwarmHub re-keyed it (P35 undo).
    func addConnectedBot(_ name: String, key: String, description: String = "", manager: Bot, backup: String?) {
        keyStore.setKey(key, for: Self.keyAccount(forProfile: name))
        if manager.hermesBaseURL == nil { namedHermesProfiles += [name] }
        let bot = Bot(name: HermesProfileNaming.botName(forProfile: name), title: "Hermes profile",
                      description: description.isEmpty ? "Hermes profile: \(name)" : description, backend: .hermes, hermesProfile: name)
        bot.hermesBaseURL = manager.hermesBaseURL; bot.adoptedKeyBackup = backup
        bots.append(bot)
    }

    /// Launch: once per connection per launch, quietly; nothing is asked (the section offers Connect).
    func discoverBoxesOnLaunch() async {
        var seen: [String] = []
        for bot in connectedHermesBots() where !seen.contains(connection(of: bot)) { seen.append(connection(of: bot)) }
        for target in seen where discoveredConnections.insert(target).inserted {
            guard let manager = ensureManager(on: target) else { continue }
            await discoverBox(manager: manager)
        }
    }

    /// Settings → "Add all bots from this box": every Hermes connection again; plain lines, and the batch to confirm.
    func addAllBotsFromBoxes() async -> (lines: [String], offer: AdoptionOffer?) {
        var targets: [String] = []
        for bot in connectedHermesBots() where !targets.contains(connection(of: bot)) { targets.append(connection(of: bot)) }
        guard !targets.isEmpty else { return ([BoxCopy.noBox], nil) }
        var lines: [String] = [], offer: AdoptionOffer?
        for target in targets {
            discoveredConnections.insert(target)
            guard let manager = ensureManager(on: target) else { lines.append(BoxCopy.noManager); continue }
            guard let scan = await discoverBox(manager: manager) else { lines.append(BoxCopy.couldNotList(manager.name)); continue }
            lines.append(BoxCopy.scanned(scan))
            if scan.needsKey.contains("default"), boundBot("default", manager: manager) == nil { lines.append(BoxCopy.mainBotKey) }
            let adoptable = (boxProfiles[target] ?? []).filter { $0.state == .adoptable || $0.state == .failed }.map(\.name)
            if offer == nil, !adoptable.isEmpty { offer = AdoptionOffer(managerID: manager.id, managerName: manager.name, names: adoptable) }
        }
        return (lines, offer)
    }

    // MARK: Adoption

    /// The confirmation's yes: one visible turn in the manager's chat runs "Connect bots" for the allowed names (never
    /// `default`, the manager, typed-key or bound profiles). False when nothing may be connected or a turn is running.
    @discardableResult func startAdoption(_ names: [String], manager: Bot) -> Bool {
        guard isManager(manager), manager.backend == .hermes, isIdle else { return false }
        let profile = manager.hermesProfile ?? "default", target = connection(of: manager)
        let allowed = BoxAdoption.adoptable(names, managerProfile: profile, typed: typedKeyProfiles, bound: boundProfiles(on: target))
        guard !allowed.isEmpty, let template = managerRecipeTemplate(.box),
              let instructions = BoxAdoption.adoptInstructions(template: template, managerProfile: profile, names: allowed) else { return false }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile, instructions: instructions)
        managementExchanges[manager.id] = nil; pendingAdoptions[manager.id] = allowed
        setBoxState(allowed, .adopting, on: target)
        open(manager); openThreadID = nil
        guard send(text: "Connect \(allowed.map(HermesProfileNaming.botName(forProfile:)).joined(separator: ", ")) to \(AppConstants.name).") else {
            pendingSkillInstalls[manager.id] = nil; pendingAdoptions[manager.id] = nil; setBoxState(allowed, .adoptable, on: target); return false
        }
        return true
    }

    /// `bots_adopted`: each name SwarmHub asked for that the manager reports ok is probed with its derived key (retried
    /// over ~10 s while Hermes picks up the new .env) and added with its backup name; anything else is failed.
    func finishAdoption(_ results: [SwarmhubOp.AdoptionResult], manager: Bot) async {
        let asked = pendingAdoptions.removeValue(forKey: manager.id) ?? results.map(\.name)
        let target = connection(of: manager)
        var added: [String] = [], failed: [String] = []
        for name in asked where boundBot(name, manager: manager) == nil {
            guard let row = results.first(where: { $0.name == name }), row.ok,
                  case .reachable(let key) = await probeDerived(name, manager: manager) else { failed.append(name); continue }
            addConnectedBot(name, key: key, manager: manager, backup: row.backup ?? ""); added.append(name)
        }
        var left = (boxProfiles[target] ?? []).filter { !added.contains($0.name) }
        for name in failed {
            if let index = left.firstIndex(where: { $0.name == name }) { left[index].state = .failed }
            else { left.append(BoxProfile(name: name, hasKey: true, state: .failed)) }
        }
        boxProfiles[target] = left.isEmpty ? nil : left
        if !added.isEmpty { removeSampleBots() }
        notice(BoxCopy.adopted(added: added, failed: failed), in: manager)
    }

    func setBoxState(_ names: [String], _ state: BoxProfile.State, on target: String) {
        guard var rows = boxProfiles[target] else { return }
        for index in rows.indices where names.contains(rows[index].name) { rows[index].state = state }
        boxProfiles[target] = rows
    }

    /// The sidebar's Connect on a row SwarmHub may re-key: the confirmation sheet for that one bot.
    func offerAdoption(_ profile: BoxProfile, on target: String) {
        guard profile.state != .needsKey, let manager = ensureManager(on: target) else { return }
        adoptionOffer = AdoptionOffer(managerID: manager.id, managerName: manager.name, names: [profile.name])
    }

    // MARK: Undo

    /// "Restore this bot's old key": the manager puts the backup back (a visible turn); on its ok SwarmHub forgets the key.
    @discardableResult func restoreOldKey(_ bot: Bot) -> Bool {
        guard let backup = bot.adoptedKeyBackup, let profile = bot.hermesProfile, let manager = manager(for: bot), manager.id != bot.id,
              manager.backend == .hermes, isIdle, let template = managerRecipeTemplate(.box),
              let instructions = BoxAdoption.restoreInstructions(template: template, managerProfile: manager.hermesProfile ?? "default", name: profile, backup: backup)
        else { return false }
        pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile, instructions: instructions)
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: "Restore \(bot.name)’s old key.") else { pendingSkillInstalls[manager.id] = nil; return false }
        return true
    }

    /// `key_restored`: on ok, the bot's stored key is removed (it is no longer connected); its chats stay.
    func finishRestore(_ name: String, ok: Bool, manager: Bot) {
        guard let bot = boundBot(name, manager: manager), bot.adoptedKeyBackup != nil, bot.id != manager.id else { return }
        guard ok else { notice(BoxCopy.restoreFailed(bot.name), in: manager); return }
        keyStore.setKey("", for: Self.keyAccount(forProfile: name))
        bot.adoptedKeyBackup = nil
        notice(BoxCopy.restored(bot.name), in: manager)
    }

    // MARK: Sample bots (D6)

    /// Bots that talk to a real box or Gateway.
    var hasRealBots: Bool { bots.contains { ($0.backend == .hermes || $0.backend == .openClaw) && !$0.isDemo && !$0.isReadOnlyArchive } }

    /// Removes the sample bots and their chats once a real bot exists ("Look around with sample agents" still makes them).
    func removeSampleBots() {
        guard hasRealBots else { return }
        let samples = Set(bots.filter(\.isDemo).map(\.id))
        guard !samples.isEmpty else { return }
        bots.removeAll { samples.contains($0.id) }
        for group in groups { group.memberIDs.removeAll { samples.contains($0) } }
        approvals.removeAll { $0.botID.map(samples.contains) == true }
        for id in samples { subAgentTasks[id] = nil; drafts.set("", for: id) }
        if let selected = selectedBot, samples.contains(selected.id) { selectedBot = nil; if selectedGroup == nil { selectVisibleChat() } }
        objectWillChange.send()
    }

    /// One-time at launch: a store that already has real bots drops its sample bots.
    func migrateSampleBots() {
        guard !defaults.bool(forKey: Self.samplesMigrationKey) else { return }
        defaults.set(true, forKey: Self.samplesMigrationKey)
        guard hasRealBots, bots.contains(where: \.isDemo) else { return }
        removeSampleBots(); save()
    }
}
