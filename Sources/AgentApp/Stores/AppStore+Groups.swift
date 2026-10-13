import AppKit
import Foundation
import UserNotifications

/// One group send in progress. Stop sets `stopped`, so the members still waiting are skipped.
@MainActor final class GroupRun {
    let groupID: UUID; var stopped = false
    init(groupID: UUID) { self.groupID = groupID }
}

/// P5 group chats: membership, migration of P6 archived groups, and sequential per-bot routing.
extension AppStore {
    // MARK: Membership

    func members(of group: GroupChat) -> [Bot] { group.memberIDs.compactMap { id in bots.first { $0.id == id } } }
    func routingMembers(of group: GroupChat) -> [GroupRouting.Member] { members(of: group).map { .init(id: $0.id, name: $0.name) } }
    func defaultGroupName(_ memberIDs: [UUID]) -> String {
        ([GroupRouting.userName] + memberIDs.compactMap { id in bots.first { $0.id == id }?.name }).joined(separator: ", ")
    }

    /// "New group": needs at least two distinct bots. An empty name becomes "Konrad, A, B".
    @discardableResult func createGroup(name: String, memberIDs: [UUID]) -> GroupChat? {
        var ids: [UUID] = []
        for id in memberIDs where !ids.contains(id) && bots.contains(where: { $0.id == id && !$0.isReadOnlyArchive }) { ids.append(id) }
        guard ids.count >= 2 else { errorMessage = "Pick at least two bots for a group."; return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = GroupChat(name: trimmed.isEmpty ? defaultGroupName(ids) : trimmed, memberIDs: ids)
        groups.append(group); open(group); save()
        return group
    }

    func renameGroup(_ group: GroupChat, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != group.name else { return }
        group.name = trimmed; objectWillChange.send(); save()
    }

    func addMember(_ bot: Bot, to group: GroupChat) {
        guard !group.memberIDs.contains(bot.id), !bot.isReadOnlyArchive else { return }
        group.memberIDs.append(bot.id); objectWillChange.send(); save()
    }

    /// The bot's group session is kept, so adding it back continues the same Hermes session.
    func removeMember(_ botID: UUID, from group: GroupChat) {
        group.memberIDs.removeAll { $0 == botID }; objectWillChange.send(); save()
    }

    func deleteGroup(_ group: GroupChat) {
        grokHistory.remove(group.id); groups.removeAll { $0.id == group.id }
        if selectedGroup?.id == group.id { selectedGroup = nil }
        objectWillChange.send(); save()
    }

    func open(_ group: GroupChat) {
        if selectedGroup?.id != group.id { replyTo = nil }
        selectedGroup = group; openThreadID = nil
        if group.isUnread { group.unreadCount = 0; group.manualUnread = false; save() }
    }

    func markUnread(_ group: GroupChat) { group.manualUnread = true; objectWillChange.send(); save() }

    /// Group members by Grok source id, then by name (Grok-imported bots first, demo bots last). The user and
    /// unknown names are skipped.
    func resolveMembers(_ entries: [(name: String, sourceID: String?)]) -> [UUID] {
        let candidates = bots.filter { !$0.isReadOnlyArchive }
        var ids: [UUID] = []
        for entry in entries {
            let named = candidates.filter { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            let match = entry.sourceID.flatMap { source in candidates.first { $0.grokSourceID == source } }
                ?? named.first { $0.grokSourceID != nil } ?? named.first { !$0.isDemo } ?? named.first
            if let match, !ids.contains(match.id) { ids.append(match.id) }
        }
        return ids
    }

    /// P6 stored an imported Grok group as a read-only bot listing member names. Each becomes a group with
    /// the same id (so its `grok-history/<id>.json` archive stays attached) and resolved members.
    @discardableResult func migrateArchivedGroups() -> [GroupChat] {
        let archived = bots.filter(\.isReadOnlyArchive)
        guard !archived.isEmpty else { return [] }
        var migrated: [GroupChat] = []
        for old in archived {
            let ids = resolveMembers((old.archivedMembers ?? []).map { ($0, nil) })
            let group = GroupChat(id: old.id, name: old.name, memberIDs: ids, messages: old.messages, createdAt: old.createdAt)
            group.grokSourceID = old.grokSourceID; group.grokHistoryCount = old.grokHistoryCount
            group.isHidden = old.isHidden; group.isMuted = !old.notificationsEnabled; group.unreadCount = old.unreadCount; group.manualUnread = old.manualUnread
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group); migrated.append(group) }
        }
        bots.removeAll(where: \.isReadOnlyArchive)
        if selectedBot.map({ bot in !bots.contains(bot) }) == true { selectedBot = bots.first { !$0.isHidden } }
        migratedGroupNames = migrated.map(\.name)
        return migrated
    }

    // MARK: Sending

    /// The composer in a group: `@Name` picks recipients (none = everyone). Members answer one after another
    /// in member order, each in its own group session with the transcript since its last reply as context.
    /// While a member answers, the text steers that member's run instead.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = [], to group: GroupChat) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard !isStreaming, streamTask == nil else { return steer(text: text, attachments: attachments, group: group) }
        let members = routingMembers(of: group)
        guard !members.isEmpty else { errorMessage = "Add bots to this group first."; return false }
        let images: [String]
        do { images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) } catch { errorMessage = error.localizedDescription; return false }
        let recipients = GroupRouting.recipients(of: text, members: members)
        group.messages.append(ChatMessage(role: .user, content: text, replyToID: replyTo?.id, attachments: attachments)); replyTo = nil
        let run = GroupRun(groupID: group.id); groupRun = run
        let token = UUID(); activeStreamToken = token
        isStreaming = true; streamingConversation = group; objectWillChange.send(); save()
        streamTask = Task { [weak self] in
            guard let self else { return }
            for botID in recipients {
                guard !run.stopped, !Task.isCancelled else { break }
                guard group.memberIDs.contains(botID), let bot = bots.first(where: { $0.id == botID }) else { continue }
                await groupTurn(bot: bot, group: group, run: run, token: token, images: images)
            }
            group.activeMemberID = nil
            if activeStreamToken == token {
                isStreaming = false; streamTask = nil; activeStreamToken = nil; streamingBotID = nil; streamingAssistant = nil; streamingConversation = nil; steerAvailable = false
            }
            if groupRun === run { groupRun = nil }
            objectWillChange.send(); save()
        }
        return true
    }

    private func groupTurn(bot: Bot, group: GroupChat, run: GroupRun, token: UUID, images: [String]) async {
        if needsKey(bot) { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: no key for \(bot.hermesProfile ?? "its profile").")); return }
        let activeBackend: any AgentBackend
        do { activeBackend = try backend(for: bot) } catch { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(error.localizedDescription)")); return }
        let context = GroupRouting.context(for: .init(id: bot.id, name: bot.name), groupName: group.name, members: routingMembers(of: group), messages: group.messages)
        let assistant = ChatMessage(role: .assistant, content: "", isStreaming: true, authorID: bot.id)
        group.messages.append(assistant); group.activeMemberID = bot.id
        if activeStreamToken == token { streamingBotID = bot.id; streamingAssistant = assistant }
        objectWillChange.send()
        let wanted = sessionNamespace + GroupRouting.sessionID(group: group.id, bot: bot.id)
        var failed = false
        do {
            if group.session(for: bot.id) == nil, try await activeBackend.sessionTransport() == .nativeSessions {
                let note = { [unowned self] (text: String) in insertNote(text, in: group, before: assistant) }
                let plan = try await prepareModel(for: bot, backend: activeBackend, note: note)
                let created = try await activeBackend.createSession(title: "\(group.name) · \(bot.name)", systemPrompt: bot.persona, id: wanted)
                if let plan { try await applyModel(plan, bot: bot, sessionID: created, record: false, note: note) }
                group.hermesSessionID = created
                save()
            }
            try Task.checkCancellation()
            let sessionID = group.session(for: bot.id) ?? wanted
            let stream = try await activeBackend.send(.init(sessionID: sessionID, systemPrompt: bot.persona, messages: [(role: "user", content: context)], images: images))
            if activeStreamToken == token { steerAvailable = (try? await activeBackend.features())?.contains("run_steer") == true }
            for try await event in stream { guard !Task.isCancelled else { break }; switch event {
            case .token(let value): assistant.content += value; objectWillChange.send()
            case .status(let value): if assistant.content.isEmpty { assistant.metadata["status"] = value }
            case .subAgent(let task): subAgentTasks[bot.id, default: []].append(task)
            case .approval(var request):
                request.botID = bot.id; request.profile = bot.hermesProfile ?? "default"; request.sessionID = sessionID
                await routeApproval(request, for: bot, backend: activeBackend)
            case .completed: break
            case .failed(let value): errorMessage = "\(bot.name): \(value)"; failed = true
            } }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
        } catch let refusal as ModelRefusal { group.messages.append(ChatMessage(role: .system, content: "\(bot.name) was skipped: \(refusal.text)")); failed = true
        } catch { errorMessage = "\(bot.name): \(error.localizedDescription)"; failed = true }
        let cancelled = Task.isCancelled || run.stopped
        let session = group.session(for: bot.id) ?? wanted
        let abandoned = approvals.filter { $0.botID == bot.id && $0.sessionID == session }
        for approval in abandoned {
            appendAudit(to: bot, approval: approval, outcome: .denied, decidedBy: "system", reason: cancelled ? "Run stopped; pending approval was cancelled." : "Run ended; pending approval was cancelled.")
        }
        approvals.removeAll { abandoned.map(\.id).contains($0.id) }
        assistant.isStreaming = false; group.activeMemberID = nil
        if activeStreamToken == token { steerAvailable = false }
        let reply = assistant.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if reply.isEmpty && !cancelled { group.messages.removeAll { $0.id == assistant.id } }
        if !cancelled && !failed && !reply.isEmpty {
            if selectedGroup?.id != group.id { group.unreadCount += 1 }
            notifyIfNeeded(group: group, bot: bot, message: reply)
        }
        objectWillChange.send(); save()
    }

    /// Text typed while a member answers steers that member's running turn (`run_steer`).
    func steer(text: String, attachments: [ChatAttachment], group: GroupChat) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard steerAvailable, streamingConversation === group, let sessionID = group.hermesSessionID,
              let bot = streamingBotID.flatMap({ id in bots.first { $0.id == id } }) else { return false }
        guard attachments.isEmpty else { errorMessage = "Attachments can’t be added to a running turn; send them after it finishes."; return false }
        guard !value.isEmpty, let activeBackend = try? backend(for: bot) else { return false }
        deliverSteer(value, into: group, sessionID: sessionID, backend: activeBackend)
        return true
    }

    /// Approval outcomes land in the chat the run belongs to: the group for `group-…` sessions, else the bot.
    func approvalConversation(_ approval: ApprovalRequest, bot: Bot) -> any Conversation {
        guard let session = approval.sessionID, session.hasPrefix(sessionNamespace + "group-") else { return bot }
        return groups.first { group in session.hasPrefix("group-\(group.id.uuidString.lowercased())-") || group.sessions.values.contains(session) } ?? bot
    }

    func notifyIfNeeded(group: GroupChat, bot: Bot, message: String) {
        guard Bundle.main.bundleIdentifier != nil, !group.isMuted, UserDefaults.standard.bool(forKey: "notifications"), let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = "\(bot.name) in \(group.name)"; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
