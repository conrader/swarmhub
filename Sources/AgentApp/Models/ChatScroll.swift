import Foundation

struct ChatMessageLocation: Equatable, Sendable {
    let conversation: UUID
    enum Row: Equatable, Sendable {
        case live(UUID)
        case imported(String)
    }
    let row: Row
    init(conversation: UUID, message: UUID) { self.conversation = conversation; row = .live(message) }
    init(conversation: UUID, imported: String) { self.conversation = conversation; row = .imported(imported) }
    var id: String {
        switch row {
        case .live(let id): "message-\(conversation)-\(id)"
        case .imported(let key): "archive-\(conversation)-\(key)"
        }
    }
}

/// P50: where each chat (bot chat, group or thread, keyed by its id) was left, and whether it is away from the newest
/// message. The saved position is the top visible message; at the bottom nothing is saved, so the chat opens at the
/// newest. Views report what they show; this model decides where a chat opens, what follows and what the button says.
@MainActor final class ChatScrollModel: ObservableObject {
    enum Opening: Equatable { case newest, message(UUID) }

    /// Conversation id → its top visible message, written with the next store save (quit flushes it).
    private(set) var positions: [UUID: UUID] = [:]
    private(set) var archivePositions: [UUID: String] = [:]
    /// Conversations scrolled up from the bottom → messages that arrived below since.
    @Published private(set) var away: [UUID: Int] = [:]
    /// Conversations whose opening scroll is still settling; what the view shows meanwhile is not the user's position.
    private var opening: Set<UUID> = []

    /// Where `id` opens: its saved message when that is still shown, else the newest (a gone message is forgotten).
    func open(_ id: UUID, shown: [UUID]) -> Opening {
        opening.insert(id)
        guard let saved = positions[id], shown.contains(saved) else { positions[id] = nil; setAway(id, nil); return .newest }
        setAway(id, away[id] ?? 0)
        return .message(saved)
    }

    /// The opening scroll settled; what the view shows now is the user's position.
    func opened(_ id: UUID, top: UUID?, atBottom: Bool) {
        opening.remove(id)
        saw(id, top: top, atBottom: atBottom)
    }

    /// The view's top visible message and whether its bottom is in view.
    func saw(_ id: UUID, top: UUID?, atBottom: Bool) {
        guard !opening.contains(id) else { return }
        if atBottom { toBottom(id); return }
        guard let top else { return }
        archivePositions[id] = nil
        positions[id] = top
        if away[id] == nil { setAway(id, 0) }
    }

    /// `count` messages arrived in `id`; true = follow them (the view was at the bottom). Otherwise they count as new.
    @discardableResult func arrived(_ id: UUID, count: Int) -> Bool {
        guard let new = away[id] else { return true }
        if count > 0 { setAway(id, new + count) }
        return false
    }

    /// Streaming text follows only at the bottom.
    func follows(_ id: UUID) -> Bool { away[id] == nil }

    func readingArchive(_ id: UUID, key: String) {
        positions[id] = nil
        archivePositions[id] = key
        setAway(id, away[id] ?? 0)
    }

    /// Sending a message or Jump to latest: back at the newest.
    func toBottom(_ id: UUID) { positions[id] = nil; archivePositions[id] = nil; setAway(id, nil) }

    /// "Jump to latest", plus " · N new"; nil at the bottom.
    func jumpLabel(_ id: UUID) -> String? {
        away[id].map { $0 > 0 ? "Jump to latest · \($0) new" : "Jump to latest" }
    }

    /// store.json form; absent while empty.
    var stored: [String: String]? {
        var result = Dictionary(uniqueKeysWithValues: positions.map { ($0.key.uuidString, $0.value.uuidString) })
        for (id, key) in archivePositions { result[id.uuidString] = "archive:" + key }
        return result.isEmpty ? nil : result
    }
    func restore(_ stored: [String: String]?) {
        positions.removeAll()
        archivePositions.removeAll()
        for (key, value) in stored ?? [:] {
            guard let conversation = UUID(uuidString: key) else { continue }
            if let message = UUID(uuidString: value) { positions[conversation] = message }
            else if value.hasPrefix("archive:") { archivePositions[conversation] = String(value.dropFirst("archive:".count)) }
        }
    }

    private func setAway(_ id: UUID, _ value: Int?) { if away[id] != value { away[id] = value } }
}
