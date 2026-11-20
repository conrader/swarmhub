import Foundation

/// What Settings → Software Update shows about the servers, and what its buttons do: one `HerdrServerUpdate` per
/// server, moved by what the server answers. The app's own update is Sparkle's (`AppUpdater`).
///
/// A server is asked what it is and whether a newer signed release is out (`check`); an update asks the server to
/// install that release itself and waits for it to come back as the new version (`update`). A server that cannot
/// reach the releases gets the release from this Mac, which checks its signature first. Herdr Core and its helper
/// on project servers are updated by Herdr's own commands, run by the server (`updateCore`).
@MainActor final class SoftwareUpdateModel: ObservableObject {
    @Published private(set) var servers: [String: HerdrServerUpdate] = [:]
    /// The project servers of each server whose Herdr helper says it needs an update.
    @Published private(set) var staleMachines: [String: [String]] = [:]
    /// Each server can go back to the version its last update replaced.
    @Published private(set) var canGoBack: [String: Bool] = [:]
    /// How long the app waits for a server to come back from a restart: longer than the server's own limit for a new
    /// version to start (90 s), after which it puts the previous one back.
    var restartWait: Duration = .seconds(150)
    var restartPoll: Duration = .seconds(1)
    private var daily: Task<Void, Never>?

    /// The one the app's windows share. Checks and renders make their own.
    static let shared = SoftwareUpdateModel()
    /// `servers`: states to show as they are (renders).
    init(servers: [String: HerdrServerUpdate] = [:], staleMachines: [String: [String]] = [:], canGoBack: [String: Bool] = [:]) {
        self.servers = servers; self.staleMachines = staleMachines; self.canGoBack = canGoBack
    }

    func state(for server: HerdrServer) -> HerdrServerUpdate { servers[server.id] ?? HerdrServerUpdate() }

    private func take(_ event: HerdrServerUpdate.Event, for server: HerdrServer) {
        var state = state(for: server)
        state.take(event)
        servers[server.id] = state
        UpdateNotice.shared.serversBehind = servers.values.filter(\.isBehind).count
    }

    /// Asks every server at once.
    func refresh(store: AppStore) async {
        let list = store.herdrServers
        servers = servers.filter { id, _ in list.contains { $0.id == id } }
        await withTaskGroup(of: Void.self) { group in
            for server in list { group.addTask { await self.check(server, store: store) } }
        }
    }

    /// Looks once shortly after launch and then once a day, so the sidebar can say when a server is behind.
    func startDailyChecks(store: AppStore, environment: [String: String] = ProcessInfo.processInfo.environment, arguments: [String] = CommandLine.arguments) {
        guard daily == nil, !UpdateConfiguration.isAutomated(environment: environment, arguments: arguments), !store.isSetupPreview else { return }
        daily = Task { [weak self, weak store] in
            try? await Task.sleep(for: .seconds(45))
            while !Task.isCancelled {
                guard let self, let store else { return }
                if store.herdrConfigured { await self.refresh(store: store) }
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
            }
        }
    }

    func check(_ server: HerdrServer, store: AppStore) async {
        guard !state(for: server).isBusy else { return }
        take(.checkBegan, for: server)
        do {
            let client = try store.herdrClient(for: server)
            let status: HerdrClient.UpdateStatus
            do { status = try await client.updateStatus() } catch let failure as HerdrUpdateFailure where failure.kind == "unsupported" {
                // No update routes. A server that still answers is one from before workspace servers had versions.
                let workspace = try await client.workspace()
                take(.answered(bridge: workspace.bridge, core: workspace.version), for: server)
                if workspace.bridge != nil { take(.checkFailed(failure), for: server) }
                return
            }
            let workspace = try? await client.workspace()
            take(.answered(bridge: status.bridge, core: workspace?.version), for: server)
            canGoBack[server.id] = status.previous == true && status.last?.state == "done"
            staleMachines[server.id] = ((try? await client.machines())?.machines ?? []).filter { $0.state == "needs_update" }.map(\.name)
            do { take(.checked(try await client.checkUpdate(), canUpdate: status.canUpdate ?? true), for: server) }
            catch let failure as HerdrUpdateFailure where failure.appCanDeliver {
                // The server cannot reach the releases. This Mac looks for it.
                #if canImport(CryptoKit)
                let release = try await WorkspaceRelease.latest()
                take(.checked(release.check(current: status.bridge.version, target: status.bridge.target), canUpdate: status.canUpdate ?? true), for: server)
                #else
                take(.checkFailed(failure), for: server)
                #endif
            }
        } catch let failure as HerdrUpdateFailure { take(.checkFailed(failure), for: server) }
        catch let failure as WorkspaceRelease.Failure { take(.checkFailed(HerdrUpdateFailure(kind: "failed", message: failure.localizedDescription)), for: server) }
        catch { take(.notReached(HerdrSetupProblem.of(error).line(for: server)), for: server) }
    }

    /// Installs the release the check found, and follows the server until it is back.
    func update(_ server: HerdrServer, store: AppStore) async {
        guard let version = state(for: server).installable, let client = try? store.herdrClient(for: server) else { return }
        take(.installBegan(version: version), for: server)
        do {
            let started: HerdrClient.UpdateStarted
            do { started = try await client.applyUpdate(version: version) } catch let failure as HerdrUpdateFailure where failure.appCanDeliver {
                #if canImport(CryptoKit)
                take(.deliveryBegan(version: version), for: server)
                let release = try await WorkspaceRelease.latest()
                guard release.manifest.version == version, let target = state(for: server).bridge?.target else {
                    throw HerdrUpdateFailure(kind: "changed", message: "The newest release changed while it was being fetched. Check again.")
                }
                started = try await client.uploadUpdate(manifest: release.manifestData, signature: release.signature, program: try await release.program(for: target))
                #else
                throw failure
                #endif
            }
            take(.accepted(started), for: server)
            if started.restarting { await follow(server, client: client) }
        } catch let failure as HerdrUpdateFailure { take(.refused(failure), for: server) }
        catch { take(.refused(HerdrUpdateFailure(kind: "failed", message: error.localizedDescription)), for: server) }
    }

    /// Back to the version the last update replaced.
    func goBack(_ server: HerdrServer, store: AppStore) async {
        guard !state(for: server).isBusy, let client = try? store.herdrClient(for: server) else { return }
        do {
            let started = try await client.rollbackUpdate()
            take(.backAccepted(started), for: server)
            canGoBack[server.id] = false
            if started.restarting { await follow(server, client: client) }
        } catch let failure as HerdrUpdateFailure { take(.refused(failure), for: server) }
        catch { take(.refused(HerdrUpdateFailure(kind: "failed", message: error.localizedDescription)), for: server) }
    }

    /// Asks the restarting server what it is until it says: the new version, or the old one with the update undone.
    private func follow(_ server: HerdrServer, client: HerdrClient) async {
        let clock = ContinuousClock(), deadline = clock.now + restartWait
        while clock.now < deadline {
            try? await Task.sleep(for: restartPoll)
            guard case .restarting = state(for: server).phase else { break }
            if let status = try? await client.updateStatus() {
                take(.answered(bridge: status.bridge, core: state(for: server).coreVersion), for: server)
                take(.cameBack(version: status.bridge.version, last: status.last), for: server)
                canGoBack[server.id] = status.previous == true && status.last?.state == "done"
            }
        }
        if case .restarting = state(for: server).phase { take(.stayedAway, for: server) }
    }

    /// Herdr's own update of Core on the server, then of its helper on the project servers that need one.
    func updateCore(_ server: HerdrServer, store: AppStore) async {
        guard let client = try? store.herdrClient(for: server) else { return }
        var state = state(for: server)
        state.coreNote = "Updating Herdr Core… Your agents keep running."; servers[server.id] = state
        var lines: [String] = []
        do {
            lines.append(try await client.updateCore().line())
            for machine in staleMachines[server.id] ?? [] {
                lines.append((try await client.updateMachine(machine)).line(subject: "Herdr on \(machine)"))
            }
            staleMachines[server.id] = []
        } catch { lines.append(error.localizedDescription) }
        state = self.state(for: server)
        state.coreNote = lines.joined(separator: " ")
        if let workspace = try? await client.workspace() { state.take(.answered(bridge: workspace.bridge ?? state.bridge, core: workspace.version)) }
        servers[server.id] = state
    }

    /// Every server with a release ready, one after another. The app itself is updated last, by Sparkle, because
    /// that ends with a relaunch.
    func updateAll(store: AppStore) async {
        for server in store.herdrServers where state(for: server).installable != nil { await update(server, store: store) }
    }

    func summary(store: AppStore, updater: AppUpdater) -> SoftwareUpdateSummary {
        let app = SoftwareUpdatePane.AppLine(version: "", available: updater.available, checking: updater.isChecking,
            lastCheck: updater.lastCheck, problem: updater.problem, queued: updater.manualCheckQueued,
            unavailable: updater.unavailableReason).state
        return SoftwareUpdateSummary(app: app, servers: store.herdrServers.map(state(for:)))
    }
}
