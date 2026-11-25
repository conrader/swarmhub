import Foundation

/// Adjacent text events for one conversation. A full draft supersedes the pending text,
/// and subsequent tokens append to it. Saves and ordering boundaries drain it synchronously.
@MainActor final class TurnTextBuffer {
    private var row: ChatMessage?
    private var text = ""
    private var replacesContent = false
    private var lastTextAt: Date?
    private var deadline: Task<Void, Never>?
    private let published: (_ sidebarOrderMayChange: Bool) -> Void

    init(published: @escaping (Bool) -> Void) { self.published = published }

    func receive(_ value: String, replacing: Bool, row: ChatMessage, at date: Date) {
        if replacing {
            text = value
            replacesContent = true
        } else {
            guard !value.isEmpty else { return }
            text.append(value)
        }
        self.row = row
        lastTextAt = value.isEmpty ? nil : date
        guard deadline == nil else { return }
        deadline = Task {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            if !Task.isCancelled { flush() }
        }
    }

    func flush() {
        guard let row else { return }
        deadline?.cancel()
        deadline = nil
        self.row = nil
        let wasDated = row.contributesToSidebarDate
        if replacesContent { row.content = text } else { row.content.append(text) }
        row.lastTextAt = lastTextAt
        text = ""
        replacesContent = false
        published(wasDated != row.contributesToSidebarDate)
    }
}
