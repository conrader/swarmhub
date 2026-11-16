import Foundation

/// The setup window's Herdr path. Test saves nothing: it builds the server from the typed fields, opens the SSH
/// forward when the server needs one, and reads what the server can run. Only Add writes (`commitSetupHerdr`).
extension AppStore {
    /// The id the draft's server is tested and saved under: a saved server at the same place keeps its id (Add then
    /// updates it), otherwise a new one (`newHerdrServerID`).
    func setupHerdrID(for draft: HerdrServerDraft) -> String {
        guard let candidate = draft.server(id: "") else { return newHerdrServerID() }
        let saved = defaults.string(forKey: HerdrServer.listKey)?.isEmpty == false ? herdrServers : []
        return saved.first { $0.kind == candidate.kind && $0.address == candidate.address && $0.sshHost == candidate.sshHost && $0.sshUser == candidate.sshUser }?.id ?? newHerdrServerID()
    }

    /// The Herdr screen's Test. "This Mac" first looks whether anything answers on the port at all, so a Mac with no
    /// Herdr running gets the how-to-start lines instead of an error.
    func testSetupHerdr(_ draft: HerdrServerDraft) async -> HerdrSetupOutcome {
        guard let server = draft.server(id: setupHerdrID(for: draft)) else { return .failed(draft.problem ?? SetupCopy.failed) }
        if server.kind == .local, await !HerdrTunnels.answers(port: server.port) { return .nothingHere(port: server.port) }
        do {
            let tested = try await testHerdrServer(server, token: draft.typedKey)
            let key = draft.typedKey.isEmpty ? tested.token : draft.typedKey
            return .connected(server: server, key: key, starters: try await herdrStarters(client: try herdrClient(for: server, token: key)))
        } catch BackendError.unavailable(let line) where line == HerdrBackend.missingToken {
            return .failed(SetupCopy.herdrNeedsKey)
        } catch { return .failed(error.localizedDescription) }
    }

    /// Cancel, Back to Welcome or closing the window: a forward Test opened for a server that was never saved is closed.
    func abandonSetupHerdr(_ server: HerdrServer?) {
        guard let server, server.kind == .ssh, herdrServers.first(where: { $0.id == server.id }) != server else { return }
        herdrTunnels.close(server.id)
    }

    /// Starters that already have an agent on this server (shown "Already added" on S4).
    func addedHerdrStarters(_ starters: [HerdrStarter], on server: HerdrServer?) -> Set<String> {
        guard let server else { return [] }
        let missing = Set(missingHerdrStarters(starters, on: server).map(\.id))
        return Set(starters.map(\.id)).subtracting(missing)
    }

    /// S4's Add for Herdr, with no network call: saves the server (and the access key Test used, when one was typed or
    /// read from the server), adds one agent per ticked starter, removes sample agents, selects the first added agent
    /// and marks setup done. Restores everything if saving fails.
    @discardableResult func commitSetupHerdr(server: HerdrServer?, key: String?, starters: [HerdrStarter], chosen: Set<String>) throws -> [Bot] {
        guard let server else { throw SetupCommitError.notTested }
        let transaction = SetupTransaction(self)
        transaction.captureDefaults([HerdrServer.listKey, FirstRun.stateKey])
        transaction.captureBots()
        return try transaction.run {
            if let key, !key.isEmpty { transaction.setKey(key, for: server.keyAccount) }
            saveHerdrServer(server, token: nil)
            let added = addHerdrStarters(starters.filter { chosen.contains($0.id) }, on: server)
            removeSampleBots()
            if let target = added.first { selectedBot = target; selectedGroup = nil; rememberSelection(bot: target) } else { selectVisibleChat() }
            FirstRun.record(.done, in: defaults)
            objectWillChange.send()
            try saveThrowing()
            return added
        }
    }
}
