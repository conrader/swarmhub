import SwiftUI

/// A workspace may have multiple bots and group sessions. One inbox read covers the visible destinations on that server.
struct WorkspaceApprovalInbox: Equatable, Sendable {
    let server: HerdrServer
    let requests: [String: [HerdrClient.Approval]]
    let unavailable: Bool
}

struct WorkspaceAttentionReading: Equatable, Sendable {
    let server: HerdrServer
    var failures: [HerdrClient.CIFailure] = []
    var completions: [HerdrClient.JobCompletion] = []
    var unavailable = false
}

private struct WorkspaceAttentionKey: EnvironmentKey {
    static let defaultValue: [String: WorkspaceAttentionReading] = [:]
}

private struct WorkspaceApprovalKey: EnvironmentKey {
    static let defaultValue: [String: WorkspaceApprovalInbox] = [:]
}

extension EnvironmentValues {
    var workspaceAttention: [String: WorkspaceAttentionReading] {
        get { self[WorkspaceAttentionKey.self] }
        set { self[WorkspaceAttentionKey.self] = newValue }
    }
    var workspaceApprovals: [String: WorkspaceApprovalInbox] {
        get { self[WorkspaceApprovalKey.self] }
        set { self[WorkspaceApprovalKey.self] = newValue }
    }
}

extension AppStore {
    func approvalAgentNames(for bot: Bot, in group: GroupChat?) -> Set<String> {
        guard let group else { return [HerdrBackend.agentName(botName: bot.name, botID: bot.id)] }
        let sessions = [turnSessionID(in: group, bot: bot), group.session(for: bot.id)].compactMap { $0 }
        return Set(sessions.compactMap { HerdrBackend.groupRuntimeName(sessionID: $0, botID: bot.id) })
    }

    func approvals(for bot: Bot, in group: GroupChat?, inboxes: [String: WorkspaceApprovalInbox]) -> [HerdrClient.Approval] {
        guard bot.backend == .herdr else { return [] }
        let server = herdrServer(for: bot)
        guard let inbox = inboxes[server.id], inbox.server == server else { return [] }
        return approvalAgentNames(for: bot, in: group).flatMap { inbox.requests[$0] ?? [] }.sorted { $0.id < $1.id }
    }
}

struct WorkspaceApprovalReader: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @State private var inboxes: [String: WorkspaceApprovalInbox] = [:]

    @State private var attention: [String: WorkspaceAttentionReading] = [:]

    private struct Target: Identifiable, Equatable {
        let server: HerdrServer
        var names: Set<String>
        let frequent: Bool
        var id: String { server.id }
    }

    private var targets: [Target] {
        guard store.launchWorkEnabled else { return [] }
        let servers = store.herdrServers
        let frequent = store.showOnlyAttention || store.showingActivity || store.anyTurnRunning
        var byServer: [String: Target] = [:]
        func add(_ bot: Bot, _ group: GroupChat? = nil) {
            guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return }
            let server = store.herdrServer(for: bot, in: servers)
            byServer[server.id, default: Target(server: server, names: [], frequent: frequent)].names.formUnion(store.approvalAgentNames(for: bot, in: group))
        }
        for bot in store.bots where !bot.isHidden { add(bot) }
        for group in store.groups where !group.isHidden {
            for member in store.members(of: group) { add(member, group) }
        }
        var foreground = Set<String>()
        if let group = store.selectedGroup {
            for member in store.members(of: group) where member.backend == .herdr {
                add(member, group)
                foreground.insert(store.herdrServer(for: member, in: servers).id)
            }
        } else if let bot = store.selectedBot, bot.backend == .herdr, store.openHerdrHelper == nil {
            add(bot)
            foreground.insert(store.herdrServer(for: bot, in: servers).id)
        }
        return servers.compactMap { server in
            guard server.kind != .ssh || store.showOnlyAttention || store.showingActivity || foreground.contains(server.id)
                    || store.herdrTunnels.isOpen(server.id) else { return nil }
            return byServer[server.id]
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.workspaceApprovals, inboxes)
            .environment(\.workspaceAttention, attention)
            .background {
                ForEach(targets) { target in
                    Color.clear.task(id: target) { await refresh(target) }
                        .task(id: target) { await refreshAttention(target) }
                        .onDisappear { inboxes[target.id] = nil; attention[target.id] = nil }
                }
            }
    }

    private func refreshAttention(_ target: Target) async {
        while !Task.isCancelled {
            let reading: WorkspaceAttentionReading
            do {
                let client = try store.herdrClient(for: target.server)
                let result: HerdrClient.AttentionInbox = try await client.get("/api/attention")
                reading = WorkspaceAttentionReading(server: target.server, failures: result.ciFailures ?? [], completions: result.completions ?? [])
            } catch {
                reading = WorkspaceAttentionReading(server: target.server, unavailable: true)
            }
            guard !Task.isCancelled else { return }
            if attention[target.id] != reading { attention[target.id] = reading }
            do { try await Task.sleep(for: .seconds(target.frequent ? 4 : 12)) } catch { return }
        }
    }

    private func refresh(_ target: Target) async {
        while !Task.isCancelled {
            let inbox: WorkspaceApprovalInbox
            do {
                let client = try store.herdrClient(for: target.server)
                let requests = try await client.approvals(for: target.names)
                inbox = WorkspaceApprovalInbox(server: target.server, requests: requests, unavailable: false)
            } catch {
                inbox = WorkspaceApprovalInbox(server: target.server, requests: [:], unavailable: true)
            }
            guard !Task.isCancelled else { return }
            if inboxes[target.id] != inbox { inboxes[target.id] = inbox }
            let busy = target.frequent || !inbox.requests.isEmpty
            do { try await Task.sleep(for: .seconds(busy ? 2 : 8)) } catch { return }
        }
    }
}
