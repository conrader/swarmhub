import Foundation

/// P43: one piece of a reply in the order it happened: text, then a burst of steps (indices into `activity.steps`), then
/// more text.
enum ReplySegment: Equatable, Sendable {
    case text(String)
    case steps(Range<Int>)
}

/// P43: a reply is drawn text → steps → text, as it streamed. Each step keeps the text offset it started at; consecutive
/// steps with no text between them form one burst. Replies saved before P43 (steps without offsets) keep one Steps row
/// under the whole text.
/// A steps row never stands inside a paragraph: text and tool events arrive on their own clocks, so a step often
/// starts while a sentence is half written. Its row then goes after that paragraph (the sentence that announced the
/// work reads whole, then the work), between two blocks of the text. This is decided from the text each time it is
/// drawn, so a reply that is still streaming and one saved long ago are laid out by the same rule.
enum ReplyLayout {
    /// The reply's segments, or nil when it has no ordered steps (no steps, or steps saved before P43).
    static func segments(content: String, activity: ToolActivity?) -> [ReplySegment]? {
        guard let steps = activity?.steps, !steps.isEmpty, steps.allSatisfy({ $0.textOffset != nil }) else { return nil }
        let length = content.utf16.count, gaps = blockGaps(in: content)
        func place(_ step: ToolStep, after cursor: Int) -> Int { clamp(betweenBlocks(clamp(step.textOffset ?? 0, 0, length), gaps: gaps, length: length), cursor, length) }
        var segments: [ReplySegment] = []; var cursor = 0; var start = 0
        while start < steps.count {
            let offset = place(steps[start], after: cursor)
            var end = start + 1
            while end < steps.count, place(steps[end], after: cursor) == offset { end += 1 }
            let text = slice(content, cursor, offset)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.text(text)) }
            // Whitespace between two bursts does not split them.
            if case .steps(let previous)? = segments.last, previous.upperBound == start { segments[segments.count - 1] = .steps(previous.lowerBound..<end) }
            else { segments.append(.steps(start..<end)) }
            cursor = offset; start = end
        }
        let rest = slice(content, cursor, length)
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { segments.append(.text(rest)) }
        return segments
    }

    /// The reply's last text segment (its conclusion), for the sidebar preview, notifications and Copy reply; the whole
    /// text when the reply has no ordered steps.
    static func finalText(content: String, activity: ToolActivity?) -> String {
        guard let segments = segments(content: content, activity: activity) else { return content }
        for segment in segments.reversed() { if case .text(let text) = segment { return text.trimmingCharacters(in: .whitespacesAndNewlines) } }
        return content
    }

    /// Where the text may be divided, as UTF-16 ranges: the start, every run of blank lines that is not inside a code
    /// fence, and the end. A range runs from the end of one block's last line to the start of the next block's first.
    static func blockGaps(in content: String) -> [ClosedRange<Int>] {
        var gaps: [ClosedRange<Int>] = [], offset = 0, fence: Character?
        // The end of the last line with words on it, and whether a blank line followed it.
        var lastEnd = 0, blank = true
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let size = line.utf16.count, words = line.trimmingCharacters(in: .whitespaces)
            if words.isEmpty {
                if fence == nil { blank = true }
            } else {
                if blank, fence == nil { gaps.append(lastEnd...offset) }
                blank = false; lastEnd = offset + size
                if let mark = words.first, words.hasPrefix("```") || words.hasPrefix("~~~") {
                    if fence == nil { fence = mark } else if fence == mark { fence = nil }
                }
            }
            offset += size + 1
        }
        // Text that ends inside an open fence (a reply still streaming) ends where it ends.
        let length = content.utf16.count
        gaps.append((fence == nil ? lastEnd : length)...length)
        return gaps
    }

    /// `offset` when it already lies between two blocks; otherwise the end of the block it lies in.
    static func betweenBlocks(_ offset: Int, gaps: [ClosedRange<Int>], length: Int) -> Int {
        for gap in gaps {
            if gap.contains(offset) { return offset }
            if gap.lowerBound > offset { return gap.lowerBound }
        }
        return length
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int { min(max(value, low), high) }

    private static func slice(_ content: String, _ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        let utf16 = content.utf16
        let start = utf16.index(utf16.startIndex, offsetBy: from), end = utf16.index(utf16.startIndex, offsetBy: to)
        return String(content[start..<end])
    }
}

extension ChatMessage {
    /// P43: the conclusion of a reply (see `ReplyLayout.finalText`).
    var finalText: String { ReplyLayout.finalText(content: content, activity: activity) }
}
