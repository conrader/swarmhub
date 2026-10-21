import Foundation

/// Several messages picked in one transcript. ⌘-click toggles a row and makes it the anchor; ⇧-click selects the run
/// from the anchor to the clicked row, replacing the previous run (rows picked before the run stay). `order` is the
/// transcript, top to bottom.
struct MessageSelectionState: Equatable {
    private(set) var selected: Set<UUID> = []
    private(set) var anchor: UUID?
    /// What a ⇧-click run adds to: the selection when the anchor was set.
    private var base: Set<UUID> = []

    var isEmpty: Bool { selected.isEmpty }
    func contains(_ id: UUID) -> Bool { selected.contains(id) }

    mutating func toggle(_ id: UUID) {
        if selected.remove(id) == nil { selected.insert(id); anchor = id } else if anchor == id { anchor = nil }
        base = selected
    }

    /// Without an anchor (or one no longer shown) the clicked row alone is picked and becomes the anchor.
    mutating func extend(to id: UUID, order: [UUID]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            selected.insert(id); anchor = id; base = selected; return
        }
        selected = base.union(order[min(from, to)...max(from, to)])
    }

    mutating func clear() { self = MessageSelectionState() }
}

/// One picked row as it is copied.
struct CopiedMessage: Equatable {
    let author: String; let date: Date; let text: String
}

/// The plain text ⌘C puts on the pasteboard for picked messages.
enum MessageCopy {
    /// Oldest first (rows with the same time keep transcript order); each row is "Author · yyyy-MM-dd HH:mm" over its
    /// text, rows separated by a blank line.
    static func text(_ rows: [CopiedMessage], timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return rows.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map { row in
                let header = "\(row.element.author) · \(formatter.string(from: row.element.date))"
                return row.element.text.isEmpty ? header : header + "\n" + row.element.text
            }
            .joined(separator: "\n\n")
    }

    /// A row's text as the chat shows it, trimmed, then one line per attachment.
    static func body(_ text: String, attachmentNames: [String] = []) -> String {
        ([text.trimmingCharacters(in: .whitespacesAndNewlines)] + attachmentNames.map { "[Attachment: \($0)]" })
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func menuTitle(count: Int) -> String { count == 1 ? "Copy Message" : "Copy \(count) Messages" }
}
