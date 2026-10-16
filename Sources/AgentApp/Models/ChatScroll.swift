import Foundation

/// P50: where each chat (bot chat, group or thread, keyed by its id) was left, and whether it is away from the newest
/// message. The saved position is the top visible message; at the bottom nothing is saved, so the chat opens at the
/// newest. Views report what they show; this model decides where a chat opens, what follows and what the button says.
@MainActor final class ChatScrollModel: ObservableObject {
    enum Opening: Equatable { case newest, message(UUID) }

    /// Conversation id → its top visible message, written with the next store save (quit flushes it).
    private(set) var positions: [UUID: UUID] = [:]
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
        if atBottom { positions[id] = nil; setAway(id, nil); return }
        if let top { positions[id] = top }
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

    /// Sending a message or Jump to latest: back at the newest.
    func toBottom(_ id: UUID) { positions[id] = nil; setAway(id, nil) }

    /// "Jump to latest", plus " · N new"; nil at the bottom.
    func jumpLabel(_ id: UUID) -> String? {
        away[id].map { $0 > 0 ? "Jump to latest · \($0) new" : "Jump to latest" }
    }

    /// store.json form; absent while empty.
    var stored: [String: String]? {
        positions.isEmpty ? nil : Dictionary(uniqueKeysWithValues: positions.map { ($0.key.uuidString, $0.value.uuidString) })
    }
    func restore(_ stored: [String: String]?) {
        positions = Dictionary(uniqueKeysWithValues: (stored ?? [:]).compactMap { key, value in
            guard let conversation = UUID(uuidString: key), let message = UUID(uuidString: value) else { return nil }
            return (conversation, message)
        })
    }

    private func setAway(_ id: UUID, _ value: Int?) { if away[id] != value { away[id] = value } }
}
