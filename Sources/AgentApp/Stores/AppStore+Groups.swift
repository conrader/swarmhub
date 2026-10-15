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
        ([userName] + memberIDs.compactMap { id in bots.first { $0.id == id }?.name }).joined(separator: ", ")
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
        if selectedGroup?.id == group.id { selectVisibleChat() }
        objectWillChange.send(); save()
    }

    func open(_ group: GroupChat, remember: Bool = true) {
        if selectedGroup?.id != group.id { replyTo = nil }
        selectedGroup = group; openThreadID = nil; showingReports = false
        if remember { rememberSelection(group: group) }
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
        if selectedBot.map({ bot in !bots.contains(bot) }) == true { selectVisibleChat() }
        migratedGroupNames = migrated.map(\.name)
        return migrated
    }

    // MARK: Sending

    /// The composer in a group: `@Name` picks recipients (none = everyone). Members answer one after another
    /// in member order, each in its own group session with the transcript since its last reply as context.
    /// While a member answers, the text steers that member's run instead.
    /// P38: `recipientIDs` (a card's author) overrides the mentions and never steers; `sourceMessageID` is the card.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = [], to group: GroupChat, recipientIDs: [UUID]? = nil, sourceMessageID: UUID? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard !isStreaming, streamTask == nil else { return recipientIDs == nil && steer(text: text, attachments: attachments, group: group) }
        let members = routingMembers(of: group)
        guard !members.isEmpty else { errorMessage = "Add bots to this group first."; return false }
        if let recipientIDs, recipientIDs.isEmpty || !recipientIDs.allSatisfy({ id in members.contains { $0.id == id } }) { return false }
        let ambiguous = recipientIDs == nil ? GroupRouting.ambiguousMentions(in: text, members: members) : []
        guard ambiguous.isEmpty else {
            errorMessage = "More than one member is called \(ambiguous.joined(separator: ", ")). Pick one from the @ list (it adds the #id)."; return false
        }
        let images: [String]
        do { images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) } catch { errorMessage = error.localizedDescription; return false }
        let recipients = recipientIDs ?? GroupRouting.recipients(of: text, members: members); steerHint = nil
        let message = ChatMessage(role: .user, content: text, replyToID: sourceMessageID ?? replyTo?.id, attachments: attachments)
        group.messages.append(message); replyTo = nil
        group.round = GroupRound(userMessageID: message.id, remaining: recipients, active: nil)
        let run = GroupRun(groupID: group.id); groupRun = run
        let token = UUID(); activeStreamToken = token
        isStreaming = true; streamingConversation = group; objectWillChange.send(); save()
        streamTask = Task { [weak self] in
            await self?.runGroupRound(group: group, run: run, token: token, recipients: recipients, images: images, trigger: message)
        }
        return true
    }

    /// Text typed while a member answers steers that member's running turn (`run_steer`). P28: always queued here (Stop
    /// would end the whole round); the reply continues below the bubble once the steer lands (D5).
    func steer(text: String, attachments: [ChatAttachment], group: GroupChat) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard steerAvailable, streamingConversation === group, let sessionID = group.hermesSessionID,
              let bot = streamingBotID.flatMap({ id in bots.first { $0.id == id } }) else { return false }
        guard attachments.isEmpty else { errorMessage = "Attachments can’t be added to a running turn; send them after it finishes."; return false }
        guard !value.isEmpty, let activeBackend = try? backend(for: bot) else { return false }
        noteFirstSteer()
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
