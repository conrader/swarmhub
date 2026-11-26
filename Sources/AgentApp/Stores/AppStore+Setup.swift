import Foundation
import SwiftUI

/// The setup window's commit errors, the simple Settings page's connection line and Test, and the user's name.
extension AppStore {
    enum SetupCommitError: Error, Equatable { case nothingChosen, notTested, saveFailed }

    /// Shown in group headers, Members and the group context; never stored in transcripts.
    var userName: String { UserIdentity.name(defaults: defaults) }

    /// The bots under the sidebar's "Hidden chats": sample bots stop being listed once a server is set up.
    var hiddenChatBots: [Bot] { let configured = herdrConfigured; return bots.filter { $0.isHidden && !($0.isDemo && configured) } }

    /// Agents that run on a Herdr server (not samples or archives).
    var herdrAgents: [Bot] { bots.filter { $0.backend == .herdr && !$0.isDemo && !$0.isReadOnlyArchive } }

    /// The simple page's status line, from the settings only: no network on open.
    var herdrStatusLine: String {
        guard herdrConfigured || !herdrAgents.isEmpty else { return SimpleCopy.notConnected }
        let servers = herdrServers
        return servers.count == 1 ? SimpleCopy.connected(to: servers[0].name, agents: herdrAgents.count) : SimpleCopy.connectedServers(servers.count, agents: herdrAgents.count)
    }

    /// The simple page's Test: each server's own Test line, or why it failed. It adds no agents; an access
    /// token read from an SSH server for the first time is kept.
    func testHerdrPlain() async -> [String] {
        var lines: [String] = []
        for server in herdrServers {
            do {
                let tested = try await testHerdrServer(server)
                if let found = tested.token { setHerdrToken(found, for: server) }
                lines.append(SimpleCopy.serverSaid(server.name, tested.line))
            }
            catch { lines.append(SimpleCopy.serverSaid(server.name, error.localizedDescription)) }
        }
        return lines
    }

    /// "Look around with sample agents": the demo bots, labelled as samples, removed once a real bot exists.
    func loadSamples() {
        guard !bots.contains(where: \.isDemo) else { bots.filter(\.isDemo).forEach { $0.isHidden = false }; selectVisibleChat(); save(); return }
        let real = bots
        loadDemoData()
        bots += real
        selectVisibleChat(); save()
    }

    /// Opens the setup window (its own scene), restarted for this app's state.
    func openSetup(openWindow: OpenWindowAction, forGrok: Bool = false, export: Bool = false) {
        guard storeRestoreOffer == nil, persistenceEnabled else { return }
        setupForGrok = forGrok
        grokStartsWithExport = export
        setupGeneration += 1
        openWindow(id: SetupView.windowID)
    }

    // MARK: Sample bots

    static let samplesMigrationKey = "p35.samplesRemoved"

    /// A real bot is one that runs on a server (not a sample, not the local mock, not an archive).
    var hasRealBots: Bool { FirstRun.hasRealAgents(bots) }

    /// Removes the sample bots and their chats once a real bot exists ("Look around with sample agents" still makes them).
    func removeSampleBots() {
        guard hasRealBots else { return }
        let samples = Set(bots.filter(\.isDemo).map(\.id))
        guard !samples.isEmpty else { return }
        bots.removeAll { samples.contains($0.id) }
        for group in groups { for id in group.memberIDs where samples.contains(id) { group.removeWorkflowMember(id) } }
        for id in samples { drafts.set("", for: id) }
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
