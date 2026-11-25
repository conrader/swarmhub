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
    /// A sample-only workspace can try group chats. Once real bots are available, prefer them.
    func groupCandidates(including selected: Set<UUID> = []) -> [Bot] {
        let writable = bots.filter { !$0.isReadOnlyArchive }
        let hasRealBots = writable.contains { !$0.isDemo }
        return writable.filter { !$0.isDemo || selected.contains($0.id) || (!hasRealBots && !$0.isHidden) }
    }

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

    /// Resolve captured card authors, mentions and reply targets before choosing a turn.
    @discardableResult func send(text: String, attachments: [ChatAttachment] = [], to group: GroupChat, recipientIDs: [UUID]? = nil, sourceMessageID: UUID? = nil, queueChoice: Bool = false, metadata: [String: String] = [:]) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return false }
        guard storeRestoreOffer == nil, groups.contains(where: { $0 === group }) else { return false }
        let members = routingMembers(of: group)
        guard !members.isEmpty else { errorMessage = "Add bots to this group first."; return false }
        if let recipientIDs, recipientIDs.isEmpty || !recipientIDs.allSatisfy({ id in members.contains { $0.id == id } }) { return false }
        let ambiguous = recipientIDs == nil ? GroupRouting.ambiguousMentions(in: text, members: members) : []
        guard ambiguous.isEmpty else {
            errorMessage = "More than one member is called \(ambiguous.joined(separator: ", ")). Pick one from the @ list (it adds the #id)."; return false
        }
        let images: [String]
        do { images = try attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:)) } catch { errorMessage = error.localizedDescription; return false }
        let message = ChatMessage(role: .user, content: text, metadata: metadata, replyToID: sourceMessageID ?? draftReplyIDs[group.id], attachments: attachments)
        let mentioned = GroupRouting.mentions(in: text, members: GroupRouting.mentionable(members))
        let source = message.replyToID.flatMap { id in group.messages.first { $0.id == id } }
        guard message.replyToID == nil || source != nil else { errorMessage = "The original group message is unavailable."; return false }
        if !message.isDraftApproval, message.metadata[ChoiceReply.quoteKey] == nil, let source {
            message.metadata[ChoiceReply.quoteKey] = String(SwarmhubBlock.visibleText(source.content).suffix(1200))
        }
        let targeted = recipientIDs ?? (!mentioned.isEmpty ? mentioned : source?.authorID.map { [$0] })
        if !isIdle(group) {
            let active = runningTurns.values.filter { $0.conversation === group }
            let ids = targeted ?? (active.count == 1 ? active.compactMap(\.botID) : [])
            guard !ids.isEmpty, ids.allSatisfy({ id in members.contains { $0.id == id } }) else {
                errorMessage = "Choose a group member for this follow-up."
                return false
            }
            let recipients = ids.compactMap { id in bots.first { $0.id == id } }
            do {
                for bot in recipients {
                    try validateArtifactAccess(message, botID: bot.id)
                    if bot.backend == .herdr, !validateGroupDraft(message.modelText, attachments: attachments, bot: bot) { return false }
                }
            } catch { presentError(error.localizedDescription, reason: .attachment); return false }
            // Per-recipient receipts distinguish a live steer from a new turn or capacity wait.
            for bot in recipients {
                let row = ChatMessage(role: .user, content: text, metadata: message.metadata,
                                      replyToID: message.replyToID, attachments: attachments)
                row.metadata[TurnWaitCopy.recipients] = bot.id.uuidString
                if let turn = active.first(where: { $0.botID == bot.id }) {
                    guard steer(row, bot: bot, turn: turn) else { return false }
                } else {
                    captureAttachments(row, readers: [bot.id])
                    group.messages.append(row)
                    if let reason = turnCapacityProblem(for: [bot]) {
                        if !waitForTurn(row, in: group, reason: reason) {
                            row.metadata[SteerKey.steer] = "failed"
                            group.messages.append(row)
                            addWarning("The capacity wait could not be saved.", in: group, after: row)
                            save()
                        }
                    }
                    else { startGroupMember(bot, in: group, trigger: row, images: images) }
                }
            }
            draftReplyIDs[group.id] = nil
            return true
        }
        let recipients = targeted ?? GroupRouting.recipients(of: text, members: members)
        guard recipients.allSatisfy({ id in members.contains { $0.id == id } }) else { return false }
        do { for id in recipients { try validateArtifactAccess(message, botID: id) } }
        catch { presentError(error.localizedDescription, reason: .attachment); return false }
        for bot in bots where recipients.contains(bot.id) && bot.backend == .herdr {
            guard validateGroupDraft(message.modelText, attachments: attachments, bot: bot) else { return false }
        }
        let full = turnCapacityProblem(for: recipients.compactMap { id in bots.first { $0.id == id } })
        if let full, let recipientIDs, !queueChoice {
            let author = recipientIDs.count == 1 ? bots.first { $0.id == recipientIDs[0] } : nil
            presentError(full, reason: .capacity, bot: author)
            return false
        }
        steerHint = nil
        if let targeted {
            message.metadata[TurnWaitCopy.recipients] = targeted.map(\.uuidString).joined(separator: ",")
        }
        captureAttachments(message, readers: recipients)
        group.messages.append(message); draftReplyIDs[group.id] = nil
        if let reason = full ?? (hasWaitingTurn(in: group) ? TurnWaitCopy.behind : nil) { return waitForTurn(message, in: group, reason: reason) }
        return startGroupRound(group, message: message, recipients: recipients, images: images)
    }

    private func startGroupMember(_ bot: Bot, in group: GroupChat, trigger: ChatMessage, images: [String]) {
        let run = GroupRun(groupID: group.id)
        let slot = ConversationTurn(conversation: group, botID: bot.id, assistant: nil, groupRun: run)
        runningTurns[slot.token] = slot
        save()
        slot.task = Task {
            await groupTurn(bot: bot, group: group, run: run, token: slot.token, images: images, trigger: trigger)
            endTurn(slot.token)
            sendQueuedNextMessage()
        }
    }

    private func validateGroupDraft(_ text: String, attachments: [ChatAttachment], bot: Bot) -> Bool {
        guard validateHerdrDraft(text, attachments: attachments, bot: bot) else { return false }
        do {
            let limit = (try? herdrBackend(for: bot)).map { backend in
                groupMessageBudget(backend, hasFiles: !attachments.isEmpty)
            } ?? HerdrClient.messageBytes
            try HerdrClient.validateMessage("\(userName): \(text)", limit: limit)
            return true
        } catch { presentError(error.localizedDescription, reason: .send, bot: bot); return false }
    }

    func groupMessageBudget(_ backend: HerdrBackend, hasFiles: Bool) -> Int {
        HerdrClient.firstMessageBudget(instructions: backend.launchInstructions, hasFiles: hasFiles)
    }

    /// Starts the round answering `message`, which is already the group's last user row.
    @discardableResult func startGroupRound(_ group: GroupChat, message: ChatMessage, recipients: [UUID], images: [String]? = nil) -> Bool {
        let images = images ?? ((try? message.attachments.filter { $0.kind == .image }.map(attachmentEncoder.dataURL(for:))) ?? [])
        group.round = GroupRound(userMessageID: message.id, remaining: recipients, active: nil)
        let run = GroupRun(groupID: group.id)
        let first = recipients.first.flatMap { id in bots.first { $0.id == id } }
        let turn = beginTurn(in: group, bot: first, assistant: nil, groupRun: run)
        let token = turn.token
        objectWillChange.send(); save()
        turn.task = Task { [weak self] in
            await self?.runGroupRound(group: group, run: run, token: token, recipients: recipients, images: images, trigger: message)
        }
        return true
    }

    func notifyIfNeeded(group: GroupChat, bot: Bot, message: String) {
        guard !SilentReply.isSilent(message), Bundle.main.bundleIdentifier != nil, !group.isMuted, UserDefaults.standard.bool(forKey: "notifications"), let app = NSApp, !app.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = "\(bot.name) in \(group.name)"; content.body = String(message.prefix(140)); content.sound = .default
        UNUserNotificationCenter.current().add(.init(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
