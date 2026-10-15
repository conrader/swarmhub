import Foundation

/// P38: an artifact handed to a chat's composer from the Media tab ("Attach").
struct PendingComposerAttachment: Equatable {
    let botID: UUID
    let attachment: ChatAttachment
}

/// P38: saved documents. Every text or document attachment sent to a bot is kept in `artifacts/` with that bot (or the
/// group's recipients) as readers. A saved document can be shared with another bot, have a bot's access removed, be
/// read, exported or attached again; an attachment that came from one is checked against its access list right before
/// each bot's turn (send, a group member's turn, Retry), so a removed reader never receives it.
extension AppStore {
    func artifacts() throws -> RuntimeArtifacts {
        guard persistenceEnabled else { throw BackendError.unavailable("Saved documents are not available in this window.") }
        return RuntimeArtifacts(directory: fileURL.deletingLastPathComponent().appending(path: "artifacts"))
    }

    /// Newest first: the documents `botID` may read.
    func artifactList(for botID: UUID) throws -> [RuntimeArtifact] {
        try artifacts().records().filter { $0.ownerBotIDs.contains(botID) }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Saves the message's new text attachments for `readers` and links each to its artifact; one that came from a saved
    /// document keeps that document (no second, unrevocable copy). Best effort: the turn goes out either way.
    func captureAttachments(_ user: ChatMessage, readers: [UUID]) {
        guard persistenceEnabled, let store = try? artifacts() else { return }
        for attachment in user.attachments where attachment.kind == .text && attachment.sourceArtifactID == nil {
            guard let text = attachment.text,
                  let artifact = try? store.save(Data(text.utf8), name: attachment.name, mimeType: attachment.mimeType, owners: readers) else { continue }
            user.metadata["artifact.\(attachment.id.uuidString)"] = artifact.id.uuidString
        }
    }

    /// Throws when a saved document attached to `user` may not be read by `botID` (or failed its integrity check).
    func validateArtifactAccess(_ user: ChatMessage, botID: UUID) throws {
        for id in user.attachments.compactMap(\.sourceArtifactID) { _ = try artifacts().read(id, botID: botID) }
    }

    func shareArtifact(_ artifact: RuntimeArtifact, with botID: UUID) throws {
        guard bots.contains(where: { $0.id == botID && !$0.isReadOnlyArchive }) else { throw BackendError.unavailable("That agent was removed.") }
        let store = try artifacts()
        guard var current = try store.record(artifact.id) else { throw BackendError.unavailable("This saved document no longer exists.") }
        if !current.ownerBotIDs.contains(botID) { current.ownerBotIDs.append(botID) }
        try store.put(current); objectWillChange.send()
    }

    func revokeArtifact(_ artifact: RuntimeArtifact, from botID: UUID) throws {
        let store = try artifacts()
        guard var current = try store.record(artifact.id) else { throw BackendError.unavailable("This saved document no longer exists.") }
        guard current.ownerBotIDs.contains(where: { $0 != botID }) else { throw BackendError.unavailable("Keep at least one agent with access to this document.") }
        current.ownerBotIDs.removeAll { $0 == botID }
        try store.put(current); objectWillChange.send()
    }

    /// The document as a composer attachment for `botID`, linked back to the artifact.
    func artifactAttachment(_ artifact: RuntimeArtifact, for botID: UUID) throws -> ChatAttachment {
        let data = try artifacts().read(artifact.id, botID: botID)
        guard let text = String(data: data, encoding: .utf8), text.count <= DocumentLimits.standard.textCharacters else {
            throw BackendError.unavailable("This document is too large to attach. Export it or attach a shorter excerpt.")
        }
        return ChatAttachment(id: UUID(), kind: .text, name: artifact.name, mimeType: artifact.mimeType, byteCount: data.count, text: text,
                              summary: "Saved document", sourceArtifactID: artifact.id)
    }

    /// Media tab → Attach: the document goes into `botID`'s composer (the chat view picks it up).
    func attachToComposer(_ artifact: RuntimeArtifact, botID: UUID) throws {
        pendingComposerAttachment = PendingComposerAttachment(botID: botID, attachment: try artifactAttachment(artifact, for: botID))
    }
}
