import Foundation

/// P38 C: a voice transcript kept on this Mac, with the user's notes and the conversation it was started from.
struct SavedVoiceConversation: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date = .now
    var name: String
    var target: ConversationActionTarget?
    var contextRevision: String
    var entries: [CodexVoiceTranscript.Entry]
    var summary: String
    var exportText: String {
        "Voice conversation: \(name)\nSaved: \(createdAt.ISO8601Format())\nContext revision: \(contextRevision)\n\nNotes / handoff:\n\(summary)\n\n" + entries.map { "\($0.role == "user" ? "You" : "ChatGPT"): \($0.text)" }.joined(separator: "\n\n")
    }
}

/// `voice/conversations.json` next to store.json, newest first.
struct SavedVoiceArchive {
    let fileURL: URL

    func records() throws -> [SavedVoiceConversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([SavedVoiceConversation].self, from: Data(contentsOf: fileURL)).sorted { $0.createdAt > $1.createdAt }
    }

    /// Adds or replaces one record.
    func put(_ value: SavedVoiceConversation) throws {
        var all = try records().filter { $0.id != value.id }; all.append(value)
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
    }
}

extension AppStore {
    static let voiceSourceKey = "voiceSourceID"
    var voiceArchive: SavedVoiceArchive { SavedVoiceArchive(fileURL: fileURL.deletingLastPathComponent().appending(path: "voice/conversations.json")) }
    func saveVoice(_ value: SavedVoiceConversation) throws { try voiceArchive.put(value) }
    func savedVoice() throws -> [SavedVoiceConversation] { try voiceArchive.records() }

    /// Sends the user's reviewed instruction from a saved voice conversation into the conversation it was started from
    /// (in a group, to the member the user picked), once. Refused when that conversation is gone or the target moved.
    @discardableResult func handoffVoice(_ value: SavedVoiceConversation, text: String, target: ConversationActionTarget) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let origin = value.target, !text.isEmpty, let (bot, conversation) = actionConversation(target) else {
            errorMessage = "The original voice destination is unavailable."; return false
        }
        switch (origin, target) {
        case (.bot, .bot): guard origin == target else { return false }
        case (.group(let original, _), .group(let group, _)): guard original == group else { return false }
        default: return false
        }
        guard !conversation.messages.contains(where: { $0.metadata[Self.voiceSourceKey] == value.id.uuidString }) else {
            errorMessage = "This voice handoff has already been added to the conversation."; return false
        }
        let body = "Reviewed voice handoff from \(value.name) (\(value.createdAt.ISO8601Format())):\n\n\(text)"
        let accepted = if let group = conversation as? GroupChat {
            send(text: body, to: group, recipientIDs: [bot.id])
        } else {
            send(text: body, bot: bot, conversation: conversation, replyToID: nil)
        }
        guard accepted else { return false }
        conversation.messages.last { $0.role == .user && $0.content == body }?.metadata[Self.voiceSourceKey] = value.id.uuidString
        save(); return true
    }
}
