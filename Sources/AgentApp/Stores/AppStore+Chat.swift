import Foundation

/// Attachments, tapbacks, manual unread, Media jumps.
extension AppStore {
    // MARK: Attachments

    /// Prepares picked, dropped or pasted files; refusals are reported and skipped.
    func prepareAttachments(_ urls: [URL]) -> [ChatAttachment] {
        urls.compactMap { url in
            do { return try attachmentEncoder.prepare(fileURL: url) } catch { presentError(error.localizedDescription, reason: .attachment); return nil }
        }
    }

    /// Like `prepareAttachments`, but documents (PDF, RTF, DOC, DOCX) are read off the main actor and one
    /// file may yield several attachments. Files go in order; a refusal is reported and skips only that file.
    /// Cancelling the calling task stops between pages and leaves no page-image files behind.
    func prepareAttachmentsAsync(_ urls: [URL]) async -> [ChatAttachment] {
        var result: [ChatAttachment] = []
        let encoder = attachmentEncoder
        for url in urls {
            if Task.isCancelled { break }
            // The file picker stops its own security-scoped access as soon as it hands the URLs over.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { result += try await encoder.prepareAll(fileURL: url) }
            catch is CancellationError { break }
            catch { presentError(error.localizedDescription, reason: .attachment) }
        }
        if Task.isCancelled { encoder.discard(result); return [] }
        return result
    }

    /// Removes the files of attachments that were dropped from the composer before sending.
    func discardAttachments(_ attachments: [ChatAttachment]) { attachmentEncoder.discard(attachments) }

    func prepareAttachment(imageData: Data, name: String) -> ChatAttachment? {
        do { return try attachmentEncoder.prepare(imageData: imageData, name: name) } catch { presentError(error.localizedDescription, reason: .attachment); return nil }
    }

    func attachmentURL(_ attachment: ChatAttachment) -> URL? { attachmentEncoder.fileURL(for: attachment) }

    // MARK: Tapbacks, unread, navigation

    /// Adds or removes a tapback and saves it with the message (local only).
    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        if let index = message.reactions.firstIndex(of: emoji) { message.reactions.remove(at: index) } else { message.reactions.append(emoji) }
        objectWillChange.send(); save()
    }

    func markUnread(_ bot: Bot) { bot.manualUnread = true; objectWillChange.send(); save() }

    private var workspaceIsFrontmost: Bool {
        focusedWorkspaceWindows.map { !$0.isEmpty } ?? !launchWorkEnabled
    }

    func workspaceFocusChanged(_ id: UUID, focused: Bool) {
        if focusedWorkspaceWindows == nil { focusedWorkspaceWindows = [] }
        if !focused {
            focusedWorkspaceWindows?.remove(id)
            return
        }
        guard focusedWorkspaceWindows?.insert(id).inserted == true else { return }
        // Refocusing reads arriving replies but preserves a deliberate Mark Unread.
        if let group = selectedGroup, showsGroupChat(group), group.unreadCount > 0 {
            group.unreadCount = 0
            save()
        } else if let bot = selectedBot, showsDirectChat(bot), bot.unreadCount > 0 {
            bot.unreadCount = 0
            save()
        }
    }

    func showsGroupChat(_ group: GroupChat) -> Bool {
        !showOnlyAttention && workspaceIsFrontmost && selectedGroup?.id == group.id
    }

    func showsDirectChat(_ bot: Bot) -> Bool {
        !showOnlyAttention && workspaceIsFrontmost && selectedBot?.id == bot.id && selectedGroup == nil && openHerdrHelper?.botID != bot.id
    }

    /// Selecting a chat clears both the automatic unread count and the manual flag.
    /// `remember: false` (ui-smoke) leaves the chat restored at the next launch unchanged.
    func open(_ bot: Bot, remember: Bool = true, helper: HerdrHelperSelection? = nil, revealInSidebar: Bool = true) {
        if inspectorTerminal != nil { inspectorTerminal = nil }
        if showOnlyAttention { showOnlyAttention = false }
        selectedBot = bot; selectedGroup = nil; openHerdrHelper = helper
        if let helper, revealInSidebar { revealSession(helper, for: bot) }
        if remember { rememberSelection(bot: bot) }
        if helper == nil, bot.isUnread { bot.unreadCount = 0; bot.manualUnread = false; save() }
    }

    /// Media tab → the message in the chat.
    func jump(to item: MediaItem) {
        if let selectedBot {
            scrollTarget = ChatMessageLocation(conversation: selectedBot.id, message: item.messageID)
        }
    }
}
