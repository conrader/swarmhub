import Foundation

/// Attachments, tapbacks, manual unread, Media jumps.
extension AppStore {
    // MARK: Attachments

    /// Prepares picked, dropped or pasted files; refusals are reported and skipped.
    func prepareAttachments(_ urls: [URL]) -> [ChatAttachment] {
        urls.compactMap { url in
            do { return try attachmentEncoder.prepare(fileURL: url) } catch { errorMessage = error.localizedDescription; return nil }
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
            catch { errorMessage = error.localizedDescription }
        }
        if Task.isCancelled { encoder.discard(result); return [] }
        return result
    }

    /// Removes the files of attachments that were dropped from the composer before sending.
    func discardAttachments(_ attachments: [ChatAttachment]) { attachmentEncoder.discard(attachments) }

    func prepareAttachment(imageData: Data, name: String) -> ChatAttachment? {
        do { return try attachmentEncoder.prepare(imageData: imageData, name: name) } catch { errorMessage = error.localizedDescription; return nil }
    }

    func attachmentURL(_ attachment: ChatAttachment) -> URL? { attachmentEncoder.fileURL(for: attachment) }

    // MARK: Tapbacks, unread, navigation

    /// Adds or removes a tapback and saves it with the message (local only).
    func toggleReaction(_ emoji: String, on message: ChatMessage) {
        if let index = message.reactions.firstIndex(of: emoji) { message.reactions.remove(at: index) } else { message.reactions.append(emoji) }
        objectWillChange.send(); save()
    }

    func markUnread(_ bot: Bot) { bot.manualUnread = true; objectWillChange.send(); save() }

    /// Selecting a chat clears both the automatic unread count and the manual flag.
    /// `remember: false` (ui-smoke) leaves the chat restored at the next launch unchanged.
    func open(_ bot: Bot, remember: Bool = true) {
        selectedBot = bot; selectedGroup = nil; openHerdrHelper = nil
        if remember { rememberSelection(bot: bot) }
        if bot.unreadCount != 0 || bot.manualUnread { bot.unreadCount = 0; bot.manualUnread = false; save() }
    }

    /// Media tab → the message in the chat.
    func jump(to item: MediaItem) {
        scrollTarget = item.messageID
    }
}
