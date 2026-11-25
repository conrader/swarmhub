import Foundation

enum TranscriptRowID: Hashable {
    case message(UUID)
    case history(String)
}

/// Persistent endpoints survive lazy view recycling and history insertion. Row order is
/// supplied by the active conversation rather than dates or the currently mounted views.
struct TranscriptRange {
    struct Point: Equatable {
        let row: TranscriptRowID
        let offset: Int
    }
    var anchor: Point
    var head: Point

    /// Completing Markdown can remove delimiters before an endpoint. Most updates
    /// just append tokens, so compare the prefix through the furthest endpoint first.
    mutating func rebase(row: TranscriptRowID, from old: String, to new: String) {
        let limit = max(anchor.row == row ? anchor.offset : 0, head.row == row ? head.offset : 0)
        guard !new.utf16.starts(with: old.utf16.prefix(limit)) else { return }
        let edits = Array(new.utf16).difference(from: Array(old.utf16))
        func moved(_ point: Point) -> Point {
            guard point.row == row else { return point }
            var offset = point.offset
            for case let .remove(index, _, _) in edits.removals where index < point.offset { offset -= 1 }
            for case let .insert(index, _, _) in edits.insertions where index < offset { offset += 1 }
            return Point(row: row, offset: min(offset, new.utf16.count))
        }
        anchor = moved(anchor)
        head = moved(head)
    }

    func slice(row: TranscriptRowID, extent: NSRange, order: [TranscriptRowID: Int]) -> NSRange? {
        guard let a = order[anchor.row], let b = order[head.row], let i = order[row],
              (min(a, b)...max(a, b)).contains(i) else { return nil }
        let forward = (a, anchor.offset) <= (b, head.offset)
        let first = forward ? anchor : head, last = forward ? head : anchor
        let start = row == first.row ? max(first.offset, extent.location) : extent.location
        let end = row == last.row ? min(last.offset, NSMaxRange(extent)) : NSMaxRange(extent)
        return end >= start ? NSRange(location: start, length: end - start) : nil
    }
}
