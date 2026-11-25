import SwiftUI

/// A workspace may have multiple bots and group sessions. One inbox read covers the visible destinations on that server.
struct WorkspaceApprovalInbox: Equatable, Sendable {
    let server: HerdrServer
    let requests: [String: [HerdrClient.Approval]]
    let unavailable: Bool
}

private struct WorkspaceApprovalKey: EnvironmentKey {
    static let defaultValue: [String: WorkspaceApprovalInbox] = [:]
}

extension EnvironmentValues {
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

    private struct Target: Identifiable, Equatable {
        let server: HerdrServer
        var names: Set<String>
        let frequent: Bool
        var id: String { server.id }
    }

    private var targets: [Target] {
        guard store.launchWorkEnabled else { return [] }
        let servers = store.herdrServers
        let frequent = store.showingActivity || store.anyTurnRunning
        var byServer: [String: Target] = [:]
        func add(_ bot: Bot, _ group: GroupChat? = nil) {
            guard bot.backend == .herdr, !bot.isReadOnlyArchive else { return }
            let server = store.herdrServer(for: bot, in: servers)
            byServer[server.id, default: Target(server: server, names: [], frequent: frequent)].names.formUnion(store.approvalAgentNames(for: bot, in: group))
        }
        if store.showingActivity {
            for bot in store.bots where !bot.isHidden { add(bot) }
            for group in store.groups where !group.isHidden {
                for member in store.members(of: group) { add(member, group) }
            }
        } else if let group = store.selectedGroup {
            for member in store.members(of: group) { add(member, group) }
        } else if let bot = store.selectedBot, store.openHerdrHelper == nil {
            add(bot)
        }
        return servers.compactMap { byServer[$0.id] }
    }

    func body(content: Content) -> some View {
        content.environment(\.workspaceApprovals, inboxes)
            .background {
                ForEach(targets) { target in
                    Color.clear.task(id: target) { await refresh(target) }
                        .onDisappear { inboxes[target.id] = nil }
                }
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
