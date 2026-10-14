import Foundation

/// P35 in the setup window: after a Hermes Test, the bot that will set up the others lists the box's bots (a quiet
/// turn), the derived-key fast path runs, and S4 shows "Found N bots on this box". Nothing is stored before Add.
extension AppStore {
    /// `connection(of:)`'s form of an address.
    static func connectionKey(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// The bot that will set up the others for a tested box: the connection's manager when it has one, else the main
    /// agent (`default`) or the first agent Test reached. Its key: the stored one, or the one typed in the window.
    func setupManager(for result: SetupCheckResult, key: String) -> (name: String, profile: String, key: String, isNew: Bool)? {
        guard let baseURL = result.baseURL else { return nil }
        let target = Self.connectionKey(baseURL.absoluteString)
        if let manager = bots.first(where: { isManager($0) && $0.backend == .hermes && connection(of: $0) == target }) {
            let profile = manager.hermesProfile ?? "default"
            let stored = keyStore.key(for: Self.keyAccount(forProfile: profile))
            return stored.isEmpty ? nil : (manager.name, profile, stored, false)
        }
        guard let first = result.available.first(where: { $0.id == "default" }) ?? result.available.first else { return nil }
        let typed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let managerKey = first.id == "default" ? (typed.isEmpty ? keyStore.key(for: "hermes") : typed) : result.extraKeys[first.id] ?? ""
        let name = bots.first { $0.backend == .hermes && ($0.hermesProfile ?? "default") == first.id }?.name ?? first.name
        return managerKey.isEmpty ? nil : (name, first.id, managerKey, true)
    }

    /// Profiles the setup window must never re-key: the stored list, `default` when its key was typed, the extra lines.
    func setupTypedProfiles(_ result: SetupCheckResult, key: String) -> Set<String> {
        typedKeyProfiles.union(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["default"]).union(result.extraKeys.keys)
    }

    /// The scan S4 shows: the manager lists the box (quietly) and each other bot gets one derived-key try. Nil when no
    /// bot could list them.
    func scanBoxForSetup(_ result: SetupCheckResult, key: String) async -> SetupBoxScan? {
        guard let baseURL = result.baseURL, let manager = setupManager(for: result, key: key),
              let template = managerTemplateOverride ?? Self.bundledManagerTemplate,
              let instructions = BoxAdoption.listInstructions(template: template, managerProfile: manager.profile) else { return nil }
        let speaker = Bot(name: manager.name, backend: .hermes, hermesProfile: manager.profile)
        let backend: any AgentBackend
        if let backendFactory { guard let made = try? backendFactory(speaker) else { return nil }; backend = made }
        else { backend = HermesBackend(baseURL: baseURL, apiKey: manager.key, profile: manager.profile, session: hermesSession) }
        guard let ops = await quietBoxTurn(backend, persona: speaker.persona, request: "List every bot on this box for \(AppConstants.name).", instructions: instructions),
              let listed = ops.lazy.compactMap({ op -> [SwarmhubOp.ListedBot]? in if case .bots(let rows) = op { rows } else { nil } }).first else { return nil }
        let bound = addedProfileIDs.union(result.available.map(\.id))
        let sorted = BoxAdoption.sort(listed, managerProfile: manager.profile, typed: setupTypedProfiles(result, key: key), bound: bound)
        var scan = SetupBoxScan(managerName: manager.name, managerProfile: manager.profile, managerIsNew: manager.isNew, listed: listed.count,
                                needsKey: sorted.needsKey.map(\.name))
        let tried = sorted.candidates.filter { $0.hasKey != false }.map(\.name)
        let reachable = await withTaskGroup(of: (String, Bool).self) { group in
            for name in tried {
                group.addTask {
                    if case .reachable = await self.probeDerived(name, managerKey: manager.key, baseURL: baseURL.absoluteString, attempts: 1) { return (name, true) }
                    return (name, false)
                }
            }
            var found: Set<String> = []
            for await (name, ok) in group where ok { found.insert(name) }
            return found
        }
        for row in sorted.candidates {
            if reachable.contains(row.name) { scan.derived.append(row.name) } else { scan.adoptable.append(row.name) }
        }
        return scan
    }

    /// After Add: the new manager takes its role, typed keys are remembered, and what is left is listed in the sidebar.
    func finishSetupScan(_ scan: SetupBoxScan, result: SetupCheckResult, key: String) {
        typedKeyProfiles = setupTypedProfiles(result, key: key)
        guard let baseURL = result.baseURL else { return }
        let target = Self.connectionKey(baseURL.absoluteString)
        if scan.managerIsNew, let bot = bots.first(where: { $0.backend == .hermes && ($0.hermesProfile ?? "default") == scan.managerProfile && connection(of: $0) == target }),
           manager(for: bot) == nil {
            setCanManageBots(bot, true)
        }
        let bound = boundProfiles(on: target)
        let left = scan.needsKey.filter { !bound.contains($0) }.map { BoxProfile(name: $0, hasKey: true, state: .needsKey) }
            + scan.adoptable.filter { !bound.contains($0) }.map { BoxProfile(name: $0, hasKey: true, state: .adoptable) }
        boxProfiles[target] = left.isEmpty ? nil : left
        discoveredConnections.insert(target)
        objectWillChange.send(); save()
    }
}
