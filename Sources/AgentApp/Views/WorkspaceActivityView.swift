import SwiftUI

struct WorkspaceActivityItem: Identifiable {
    enum Section: String, CaseIterable {
        case attention = "Needs attention", working = "Working", queued = "Queued", unread = "Unread"
    }

    let chat: SidebarChat
    let section: Section
    let detail: String
    var id: UUID { chat.id }
}

extension AppStore {
    func workspaceActivity(inboxes: [String: WorkspaceApprovalInbox] = [:]) -> [WorkspaceActivityItem] {
        let chats = bots.filter { !$0.isHidden }.map(SidebarChat.bot) + groups.filter { !$0.isHidden }.map(SidebarChat.group)
        return chats.compactMap { activityItem(for: $0, inboxes: inboxes) }.sorted {
            $0.chat.displayName.localizedStandardCompare($1.chat.displayName) == .orderedAscending
        }
    }

    private func activityItem(for chat: SidebarChat, inboxes: [String: WorkspaceApprovalInbox]) -> WorkspaceActivityItem? {
        func item(_ section: WorkspaceActivityItem.Section, _ detail: String) -> WorkspaceActivityItem {
            WorkspaceActivityItem(chat: chat, section: section, detail: detail)
        }

        let conversation: any Conversation
        switch chat {
        case .bot(let bot):
            conversation = bot
            if let request = approvals(for: bot, in: nil, inboxes: inboxes).first {
                return item(.attention, "Review " + HerdrClient.Approval.visible(request.tool))
            }
            if let prompt = herdrPrompts[bot.id] { return item(.attention, prompt.title) }
            if let goal = bot.goal, goal.state == .waiting { return item(.attention, goal.detail.isEmpty ? goal.objective : goal.detail) }
            if !pendingHerdrBots(for: bot).isEmpty { return item(.attention, "Review a bot request") }
            if !pendingHerdrModels(for: bot).isEmpty { return item(.attention, "Review a model change") }
        case .group(let group):
            conversation = group
            for member in members(of: group) {
                if let request = approvals(for: member, in: group, inboxes: inboxes).first {
                    return item(.attention, "\(member.name) · Review " + HerdrClient.Approval.visible(request.tool))
                }
                if let prompt = herdrPrompt(for: member, in: group) { return item(.attention, "\(member.name) · \(prompt.title)") }
            }
        }

        if let last = conversation.messages.last(where: { $0.role == .assistant }) {
            if last.turnState == .stopped, last.metadata[TurnKey.why] == TurnKey.stopPending { return item(.working, "Waiting for stop confirmation…") }
            if last.needsTurnAttention {
                if last.stopUnconfirmed { return item(.attention, "Stop unconfirmed") }
                if last.turnState == .notSent, last.metadata[TurnKey.ambiguous] == "1" { return item(.attention, "Delivery unconfirmed") }
                return item(.attention, last.turnState == .notSent ? "Message wasn’t sent" : "Reply is incomplete")
            }
            if last.checkingSavedReply && last.turnState == .incomplete { return item(.working, "Checking for a saved reply") }
        }
        if isStreaming(in: conversation) {
            let line: String?
            switch chat {
            case .bot(let bot): line = workingLine(for: bot)
            case .group(let group): line = workingLine(for: group)
            }
            return item(.working, line ?? "Answer in progress")
        }
        if case .bot(let bot) = chat {
            if hasActiveCodingAgent(bot) { return item(.working, "Coding activity") }
            if let goal = bot.goal, goal.state == .running { return item(.working, goal.objective) }
            if let goal = bot.goal, goal.state == .queued { return item(.queued, goal.objective) }
        }
        if turns.nextMessages.contains(where: { $0.conversation === conversation }) { return item(.queued, "Message waiting to be sent") }
        guard chat.isUnread else { return nil }
        let preview = SidebarFragment.text(messages: conversation.messages, draft: nil, isWorking: false,
                                           archiveNewest: grokHistory.newestVisible(for: chat.id))
        return item(.unread, preview.isEmpty ? "Marked unread" : preview)
    }
}

struct WorkspaceActivityView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.workspaceApprovals) private var inboxes
    @Environment(\.dismiss) private var dismiss
    @State private var items: [WorkspaceActivityItem] = []

    private struct Review: Equatable, Identifiable {
        let bot: Bot
        let server: HerdrServer
        let request: HerdrClient.Approval
        var id: String { "\(bot.id)-\(server.id)-\(request.id)" }
    }

    @State private var selectedReview: Review?
    @State private var completed: [Review] = []

    private struct ServerReading {
        let server: HerdrServer
        var failures: [HerdrClient.CIFailure]
        var reviewed: Set<Int64> = []
        var completions: [HerdrClient.JobCompletion] = []
    }

    @State private var serverReadings: [String: ServerReading] = [:]

    private func ciFailures(on server: HerdrServer) -> [HerdrClient.CIFailure] {
        guard let reading = serverReadings[server.id], reading.server == server else { return [] }
        return reading.failures.filter { !reading.reviewed.contains($0.id) }
    }
    @State private var attentionUnavailable = Set<String>()

    private func completions(on server: HerdrServer) -> [HerdrClient.JobCompletion] {
        guard let reading = serverReadings[server.id], reading.server == server else { return [] }
        return reading.completions
    }

    private var servers: [HerdrServer] { inboxes.values.map(\.server).sorted { $0.id < $1.id } }

    private func refreshAttention(on server: HerdrServer) async {
        while !Task.isCancelled {
            do {
                let client = try store.herdrClient(for: server)
                let result: HerdrClient.AttentionInbox = try await client.get("/api/attention")
                guard !Task.isCancelled else { return }
                var reading = serverReadings[server.id] ?? ServerReading(server: server, failures: [])
                if reading.server != server { reading = ServerReading(server: server, failures: []) }
                reading.failures = result.ciFailures ?? []
                reading.completions = result.completions ?? []
                reading.reviewed.formIntersection(reading.failures.map(\.id))
                serverReadings[server.id] = reading
                attentionUnavailable.remove(server.id)
            } catch {
                guard !Task.isCancelled else { return }
                serverReadings[server.id] = nil
                attentionUnavailable.insert(server.id)
            }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
        }
    }

    private func reviews(in chat: SidebarChat) -> [Review] {
        func requests(_ bot: Bot, _ group: GroupChat?) -> [Review] {
            let server = store.herdrServer(for: bot)
            return store.approvals(for: bot, in: group, inboxes: inboxes).map {
                Review(bot: bot, server: server, request: $0)
            }
        }
        switch chat {
        case .bot(let bot): return requests(bot, nil)
        case .group(let group): return store.members(of: group).flatMap { requests($0, group) }
        }
    }

    private func completionRow(_ result: HerdrClient.JobCompletion, on server: HerdrServer) -> some View {
        let bot = store.bots.first { $0.id == UUID(uuidString: result.ownerBotId) && $0.backend == .herdr && store.herdrServer(for: $0) == server }
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(result.ownerName ?? bot?.name ?? result.ownerBotId) · Job \(result.verdict)")
                .font(.body.weight(.medium))
            if let detail = result.outcomeDetail, !detail.isEmpty { Text(detail) }
            Text([server.name, result.delivery, result.blocker].compactMap { $0 }.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary)
            if let bot {
                Button("Open \(bot.name) chat") { store.open(bot); dismiss() }.controlSize(.small)
            }
        }.padding(6).help(result.id)
    }

    private struct ActivitySection: Identifiable {
        let id: WorkspaceActivityItem.Section
        let rows: [WorkspaceActivityItem]
    }

    private var sections: [ActivitySection] {
        WorkspaceActivityItem.Section.allCases.compactMap { section in
            let rows = items.filter { $0.section == section }
            return rows.isEmpty ? nil : ActivitySection(id: section, rows: rows)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            ForEach(inboxes.values.filter(\.unavailable).map(\.server).sorted { $0.id < $1.id }) { server in
                Label("Can’t check approvals on \(server.name)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
            }
            ForEach(servers.filter { attentionUnavailable.contains($0.id) && inboxes[$0.id]?.unavailable == false }) { server in
                Label("Can’t check background jobs or CI on \(server.name)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
            }
            Group {
                if items.isEmpty && servers.allSatisfy({ ciFailures(on: $0).isEmpty && completions(on: $0).isEmpty }) {
                    ContentUnavailableView("No chat activity", systemImage: AppCommand.activity.icon,
                                           description: Text("Chats with pending work or unread messages appear here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if servers.contains(where: { !ciFailures(on: $0).isEmpty }) {
                                Text("Failed pull request checks").font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 10)
                                ForEach(servers) { server in
                                    ForEach(ciFailures(on: server)) { failure in
                                        WorkspaceCIFailureRow(server: server, failure: failure) {
                                            guard serverReadings[server.id]?.server == server else { return }
                                            serverReadings[server.id]?.reviewed.insert(failure.id)
                                        }
                                    }
                                }
                            }
                            if servers.contains(where: { !completions(on: $0).isEmpty }) {
                                Text("Background job results").font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 10)
                                ForEach(servers) { server in
                                    ForEach(completions(on: server)) { result in
                                        completionRow(result, on: server)
                                    }
                                }
                            }
                            ForEach(sections) { section in
                                HStack {
                                    Text(section.id.rawValue).font(.headline)
                                    Text("\(section.rows.count)").foregroundStyle(.secondary).monospacedDigit()
                                }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                                    .padding(.top, 10)
                                ForEach(section.rows) { row in
                                    Button {
                                        store.open(row.chat)
                                        dismiss()
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(row.chat.displayName).font(.body.weight(.medium))
                                                Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Spacer()
                                            if row.chat.isUnread && row.section != .unread {
                                                Circle().fill(.tint).frame(width: 7, height: 7)
                                            }
                                            Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
                                        }.padding(6).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("\(row.chat.displayName), \(row.detail)")
                                        .accessibilityValue(row.chat.isUnread ? "Unread" : "")
                                    if row.section == .attention {
                                        ForEach(reviews(in: row.chat).filter { !completed.contains($0) }) { review in
                                            if selectedReview == review {
                                                HerdrApprovalReview(request: review.request, server: review.server, keyboardDecisions: true) {
                                                    completed.append(review)
                                                    selectedReview = nil
                                                }.id(review.id).chatCard(tint: review.bot.colours)
                                            } else {
                                                Button("Inspect \(HerdrClient.Approval.visible(review.request.tool)) request") {
                                                    selectedReview = review
                                                }.controlSize(.small)
                                            }
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: 440, height: 420)
        .background {
            ForEach(servers) { server in
                Color.clear.task(id: server) { await refreshAttention(on: server) }
                    .onDisappear {
                        serverReadings[server.id] = nil
                        attentionUnavailable.remove(server.id)
                    }
            }
        }
        .task(id: inboxes) {
            // Messages and remote helper snapshots can change independently of the store's published lists.
            while !Task.isCancelled {
                items = store.workspaceActivity(inboxes: inboxes)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
