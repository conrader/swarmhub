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

struct WorkspaceReview: Equatable, Identifiable {
    let bot: Bot
    let server: HerdrServer
    let request: HerdrClient.Approval
    var id: String { "\(bot.id)-\(server.id)-\(request.id)" }

    /// Advice and the displayed model can arrive after the person opens the request.
    func refers(to other: Self) -> Bool {
        bot.id == other.bot.id && refers(to: other.request, on: other.server)
    }

    func refers(to candidate: HerdrClient.Approval, on server: HerdrServer) -> Bool {
        self.server == server && request.id == candidate.id && request.agent == candidate.agent
            && request.core == candidate.core && request.address == candidate.address && request.provider == candidate.provider
            && request.createdMs == candidate.createdMs && request.tool == candidate.tool
            && request.cwd == candidate.cwd && request.arguments == candidate.arguments
    }
}

extension AppStore {
    func workspaceReviews(in chat: SidebarChat, inboxes: [String: WorkspaceApprovalInbox]) -> [WorkspaceReview] {
        func requests(_ bot: Bot, _ group: GroupChat?) -> [WorkspaceReview] {
            let server = herdrServer(for: bot)
            return approvals(for: bot, in: group, inboxes: inboxes).map {
                WorkspaceReview(bot: bot, server: server, request: $0)
            }
        }
        switch chat {
        case .bot(let bot): return requests(bot, nil)
        case .group(let group): return members(of: group).flatMap { requests($0, group) }
        }
    }


    func workspaceActivity(inboxes: [String: WorkspaceApprovalInbox] = [:], attentionOnly: Bool = false) -> [WorkspaceActivityItem] {
        let chats = bots.filter { !$0.isHidden }.map(SidebarChat.bot) + groups.filter { !$0.isHidden }.map(SidebarChat.group)
        return chats.compactMap { activityItem(for: $0, inboxes: inboxes, attentionOnly: attentionOnly) }.sorted {
            $0.chat.displayName.localizedStandardCompare($1.chat.displayName) == .orderedAscending
        }
    }

    private func activityItem(for chat: SidebarChat, inboxes: [String: WorkspaceApprovalInbox], attentionOnly: Bool) -> WorkspaceActivityItem? {
        func item(_ section: WorkspaceActivityItem.Section, _ detail: String) -> WorkspaceActivityItem {
            WorkspaceActivityItem(chat: chat, section: section, detail: detail)
        }

        let conversation: any Conversation
        switch chat {
        case .bot(let bot):
            conversation = bot
            if let review = bot.pendingSampleReview { return item(.attention, review.title) }
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
            if !attentionOnly, last.turnState == .stopped, last.metadata[TurnKey.why] == TurnKey.stopPending { return item(.working, "Waiting for stop confirmation…") }
            if last.needsTurnAttention {
                if last.stopUnconfirmed { return item(.attention, "Stop unconfirmed") }
                if last.turnState == .notSent, last.metadata[TurnKey.ambiguous] == "1" { return item(.attention, "Delivery unconfirmed") }
                return item(.attention, last.turnState == .notSent ? "Message wasn’t sent" : "Reply is incomplete")
            }
            if !attentionOnly && last.checkingSavedReply && last.turnState == .incomplete { return item(.working, "Checking for a saved reply") }
        }
        if attentionOnly { return nil }
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
    var attentionOnly = false
    @Environment(\.workspaceAttention) private var serverReadings
    @EnvironmentObject private var store: AppStore
    @Environment(\.workspaceApprovals) private var inboxes
    @Environment(\.dismiss) private var dismiss
    @State private var items: [WorkspaceActivityItem] = []

    @State private var selectedReview: WorkspaceReview?
    @State private var completed: [WorkspaceReview] = []

    @State private var reviewedCI: [String: Set<Int64>] = [:]

    private var remainingInboxes: [String: WorkspaceApprovalInbox] {
        guard !completed.isEmpty else { return inboxes }
        return inboxes.mapValues { inbox in
            let requests = inbox.requests.mapValues { rows in
                rows.filter { request in !completed.contains { $0.refers(to: request, on: inbox.server) } }
            }
            return WorkspaceApprovalInbox(server: inbox.server, requests: requests, unavailable: inbox.unavailable)
        }
    }

    private func ciFailures(on server: HerdrServer) -> [HerdrClient.CIFailure] {
        guard let reading = serverReadings[server.id], reading.server == server else { return [] }
        return reading.failures.filter { reviewedCI[server.id]?.contains($0.id) != true }
    }

    private func completions(on server: HerdrServer) -> [HerdrClient.JobCompletion] {
        guard !attentionOnly, let reading = serverReadings[server.id], reading.server == server else { return [] }
        return reading.completions
    }

    private var servers: [HerdrServer] { store.herdrServers.filter { serverReadings[$0.id]?.server == $0 || inboxes[$0.id]?.server == $0 } }

    private func close() {
        if attentionOnly {
            if let group = store.selectedGroup { store.open(group) }
            else if let bot = store.selectedBot { store.open(bot, helper: store.openHerdrHelper) }
            else { store.showOnlyAttention = false }
        } else { dismiss() }
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
        let pending = remainingInboxes
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if attentionOnly && store.sidebarHidden { ShowSidebarItem() }
                Text(attentionOnly ? "Needs Attention" : "Activity").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if attentionOnly && (store.selectedGroup != nil || store.selectedBot != nil || store.inspectorTerminal != nil) {
                    ShowDetailsItem()
                }
                Button("Done") { close() }.keyboardShortcut(.cancelAction)
            }.padding()
            Divider()
            ForEach(inboxes.values.filter(\.unavailable).map(\.server).sorted { $0.id < $1.id }) { server in
                Label("Can’t check approvals on \(server.name)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
            }
            ForEach(servers.filter { serverReadings[$0.id]?.unavailable == true && inboxes[$0.id]?.unavailable == false }) { server in
                Label("Can’t check background jobs or CI on \(server.name)", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.top, 6)
            }
            Group {
                if items.isEmpty && servers.allSatisfy({ ciFailures(on: $0).isEmpty && completions(on: $0).isEmpty }) {
                    ContentUnavailableView(attentionOnly ? "No pending items" : "No chat activity", systemImage: AppCommand.activity.icon,
                                           description: Text(attentionOnly ? "Requests, interrupted replies and failed checks appear here." : "Chats with pending work or unread messages appear here."))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            if servers.contains(where: { !ciFailures(on: $0).isEmpty }) {
                                Text("Failed pull request checks").font(.headline).accessibilityAddTraits(.isHeader).padding(.top, 10)
                                ForEach(servers) { server in
                                    ForEach(ciFailures(on: server)) { failure in
                                        WorkspaceCIFailureRow(server: server, failure: failure) {
                                            guard serverReadings[server.id]?.server == server else { return }
                                            reviewedCI[server.id, default: []].insert(failure.id)
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
                                        if !attentionOnly { dismiss() }
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
                                        if case .bot(let bot) = row.chat, let review = bot.pendingSampleReview {
                                            SampleReviewCard(bot: bot, review: review)
                                                .reviewCard(inInbox: attentionOnly, tint: bot.colours)
                                        }
                                        if attentionOnly, case .bot(let manager) = row.chat, store.createsHerdrBots(manager) {
                                            HerdrBotRequestCard(manager: manager, showsCreatedBots: false, inInbox: true)
                                        }
                                        ForEach(store.workspaceReviews(in: row.chat, inboxes: pending)) { review in
                                            let inspecting = selectedReview?.refers(to: review) == true
                                            if attentionOnly || inspecting {
                                                HerdrApprovalReview(request: review.request, server: review.server,
                                                                    inboxBot: attentionOnly ? review.bot : nil,
                                                                    inspect: attentionOnly && !inspecting ? { selectedReview = review } : nil,
                                                                    keyboardDecisions: inspecting) {
                                                    completed.append(review)
                                                    items = store.workspaceActivity(inboxes: remainingInboxes, attentionOnly: attentionOnly)
                                                    if selectedReview?.refers(to: review) == true { selectedReview = nil }
                                                }.id(review.id).reviewCard(inInbox: attentionOnly, tint: review.bot.colours)
                                            } else {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    if let command = review.request.commandPreview {
                                                        Text(command).font(.callout.monospaced()).lineLimit(2)
                                                    }
                                                    if let reviewer = review.request.reviewer, let name = reviewer.botName,
                                                       reviewer.assessment != nil, reviewer.problem == nil {
                                                        Text("Reviewed by " + HerdrClient.Approval.visible(name))
                                                            .font(.caption).foregroundStyle(.secondary)
                                                    }
                                                    Button("Inspect \(HerdrClient.Approval.visible(review.request.tool)) request") {
                                                        selectedReview = review
                                                    }.controlSize(.small)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }.padding(.horizontal).padding(.bottom)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: attentionOnly ? nil : 440, height: attentionOnly ? nil : 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.chat)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(attentionOnly ? "workspace.attention" : "workspace.activity")
        .task(id: pending) {
            // Messages and remote helper snapshots can change independently of the store's published lists.
            while !Task.isCancelled {
                items = store.workspaceActivity(inboxes: pending, attentionOnly: attentionOnly)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
