import AppKit
import Foundation
import UserNotifications

/// One group send in progress. Stop sets `stopped`, so the members still waiting are skipped.
@MainActor final class GroupRun {
    let groupID: UUID; var stopped = false
    init(groupID: UUID) { self.groupID = groupID }
}

/// Group chats: membership, migration of archived groups, and sequential per-bot routing.
extension AppStore {
    // MARK: Membership

    func members(of group: GroupChat) -> [Bot] { group.memberIDs.compactMap { id in bots.first { $0.id == id } } }
    func routingMembers(of group: GroupChat) -> [GroupRouting.Member] { members(of: group).filter { !$0.isReadOnlyArchive }.map { .init(id: $0.id, name: $0.name) } }
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

    func removeMember(_ botID: UUID, from group: GroupChat) {
        group.memberIDs.removeAll { $0 == botID }; objectWillChange.send(); save()
    }

    func deleteGroup(_ group: GroupChat) {
        if !deletedGroupIDs.contains(group.id) { deletedGroupIDs.append(group.id) }
        discardComposerAttachments(for: group.id); grokHistory.remove(group.id); groups.removeAll { $0.id == group.id }
        if selectedGroup?.id == group.id { selectVisibleChat() }
        objectWillChange.send(); save()
    }

    func open(_ group: GroupChat, remember: Bool = true) {
        if selectedGroup?.id != group.id { replyTo = nil }
        selectedGroup = group
        if remember { rememberSelection(group: group) }
        if group.isUnread { group.unreadCount = 0; group.manualUnread = false; save() }
    }

    func markUnread(_ group: GroupChat) { group.manualUnread = true; objectWillChange.send(); save() }

    /// Group members by Grok source id, then by name (Grok-imported bots first, demo bots last). The user and
    /// unknown names are skipped.
    func resolveMembers(_ entries: [(name: String, sourceID: String?)]) -> [UUID] {
        Self.resolveMembers(entries, from: bots)
    }

    nonisolated static func resolveMembers(_ entries: [(name: String, sourceID: String?)], from bots: [Bot]) -> [UUID] {
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
        var file = storeFile
        let names = file.migrateArchivedGroups()
        guard file.bots.count != bots.count else { return [] }
        bots = file.bots; groups = file.groups
        if selectedBot.map({ bot in !bots.contains(bot) }) == true { selectVisibleChat() }
        migratedGroupNames = names
        return groups.filter { names.contains($0.name) }
    }

    // MARK: Sending

    func groupRecipients(of text: String, in group: GroupChat) -> [Bot] {
        let ids = GroupRouting.recipients(of: text, members: routingMembers(of: group))
        return ids.compactMap { id in bots.first { $0.id == id } }
    }

    /// The composer in a group: `@Name` picks recipients (none = everyone). Members answer one after another
    /// in member order, each in its own group session with the transcript since its last reply as context.
    /// While a member answers, the text steers that member's run instead.
    /// `recipientIDs` (a card's author) overrides the mentions and never steers; `sourceMessageID` is the card.
    /// One round at a time per group; direct chats with the same bots stay free. At the turn limit the composer's
    /// message waits as the group's next message (a card's send is refused).
    @discardableResult func send(text: String, attachments: [ChatAttachment] = [], to group: GroupChat, recipientIDs: [UUID]? = nil, sourceMessageID: UUID? = nil) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard isIdle(group) else { return recipientIDs == nil && steer(text: text, attachments: attachments, group: group) }
        let members = routingMembers(of: group)
        guard !members.isEmpty else { errorMessage = "Add bots to this group first."; return false }
        if let recipientIDs, recipientIDs.isEmpty || !recipientIDs.allSatisfy({ id in members.contains { $0.id == id } }) { return false }
        let ambiguous = recipientIDs == nil ? GroupRouting.ambiguousMentions(in: text, members: members) : []
        guard ambiguous.isEmpty else {
            errorMessage = "More than one member is called \(ambiguous.joined(separator: ", ")). Pick one from the @ list (it adds the #id)."; return false
        }
        let images: [String]
        do { images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) } catch { errorMessage = error.localizedDescription; return false }
        let recipients = recipientIDs ?? GroupRouting.recipients(of: text, members: members)
        for bot in bots where recipients.contains(bot.id) && bot.backend == .herdr {
            guard validateGroupDraft(text, attachments: attachments, bot: bot) else { return false }
        }
        let full = turnCapacityProblem(for: recipients.compactMap { id in bots.first { $0.id == id } })
        if let full, recipientIDs != nil { errorMessage = full; return false }
        steerHint = nil
        let message = ChatMessage(role: .user, content: text, replyToID: sourceMessageID ?? replyTo?.id, attachments: attachments)
        captureAttachments(message, readers: recipients)
        group.messages.append(message); replyTo = nil
        if let reason = full ?? (hasWaitingTurn(in: group) ? TurnWaitCopy.behind : nil) { return waitForTurn(message, in: group, reason: reason) }
        return startGroupRound(group, message: message, recipients: recipients, images: images)
    }

    private func validateGroupDraft(_ text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        guard validateHerdrDraft(text, attachments: attachments) else { return false }
        do {
            let limit = (try? herdrBackend(for: bot)).map { backend in
                groupMessageBudget(backend, hasFiles: !attachments.isEmpty)
            } ?? HerdrClient.messageBytes
            try HerdrClient.validateMessage("\(userName): \(text)", limit: limit)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func groupMessageBudget(_ backend: HerdrBackend, hasFiles: Bool) -> Int {
        HerdrClient.firstMessageBudget(instructions: backend.launchInstructions, hasFiles: hasFiles)
    }

    /// Starts the round answering `message`, which is already the group's last user row.
    @discardableResult func startGroupRound(_ group: GroupChat, message: ChatMessage, recipients: [UUID], images: [String]? = nil) -> Bool {
        let images = images ?? ((try? message.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:))) ?? [])
        group.round = GroupRound(userMessageID: message.id, remaining: recipients, active: nil)
        let run = GroupRun(groupID: group.id)
        let turn = beginTurn(in: group, bot: nil, assistant: nil, groupRun: run)
        let token = turn.token
        objectWillChange.send(); save()
        turn.task = Task { [weak self] in
            await self?.runGroupRound(group: group, run: run, token: token, recipients: recipients, images: images, trigger: message)
        }
        return true
    }

    /// Text typed while a member answers steers that member's running turn. Never Stop here (it would end the whole
    /// round); the reply continues below the bubble once the steer lands. What cannot steer (a member that holds
    /// messages, between members, attachments) waits as the group's next message and goes when the round ends.
    func steer(text: String, attachments: [ChatAttachment], group: GroupChat) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let turn = turn(in: group), turn.steerAvailable, attachments.isEmpty, !value.isEmpty,
           let bot = turn.botID.flatMap({ id in bots.first { $0.id == id } }), let activeBackend = try? backend(for: bot) {
            noteFirstSteer()
            deliverSteer(value, into: group, sessionID: turnSessionID(in: group, bot: bot), backend: activeBackend)
            return true
        }
        return queueAfterRound(text: text, attachments: attachments, group: group)
    }

    /// The message goes into the group now and waits there as its next message (`waitForTurn`); the running
    /// round is never stopped. Mentions are checked as for a send.
    func queueAfterRound(text: String, attachments: [ChatAttachment], group: GroupChat) -> Bool {
        let members = routingMembers(of: group)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty, !members.isEmpty else { return false }
        let ambiguous = GroupRouting.ambiguousMentions(in: text, members: members)
        guard ambiguous.isEmpty else {
            errorMessage = "More than one member is called \(ambiguous.joined(separator: ", ")). Pick one from the @ list (it adds the #id)."; return false
        }
        do { _ = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) } catch { errorMessage = error.localizedDescription; return false }
        steerHint = nil
        let recipients = GroupRouting.recipients(of: text, members: members)
        for bot in bots where recipients.contains(bot.id) && bot.backend == .herdr {
            guard validateGroupDraft(text, attachments: attachments, bot: bot) else { return false }
        }
        let message = ChatMessage(role: .user, content: text, replyToID: replyTo?.id, attachments: attachments)
        captureAttachments(message, readers: recipients)
        group.messages.append(message)
        return waitForTurn(message, in: group, reason: SteerCopy.afterTurn)
    }

    func notifyIfNeeded(group: GroupChat, bot: Bot, message: String) {
        guard !SilentReply.isSilent(message), Bundle.main.bundleIdentifier != nil, !group.isMuted, UserDefaults.standard.bool(forKey: "notifications"), let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = "\(bot.name) in \(group.name)"; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
