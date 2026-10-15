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
enum ReplyLayout {
    /// The reply's segments, or nil when it has no ordered steps (no steps, or steps saved before P43).
    static func segments(content: String, activity: ToolActivity?) -> [ReplySegment]? {
        guard let steps = activity?.steps, !steps.isEmpty, steps.allSatisfy({ $0.textOffset != nil }) else { return nil }
        let length = content.utf16.count
        var segments: [ReplySegment] = []; var cursor = 0; var start = 0
        while start < steps.count {
            let offset = clamp(steps[start].textOffset ?? 0, cursor, length)
            var end = start + 1
            while end < steps.count, clamp(steps[end].textOffset ?? 0, cursor, length) == offset { end += 1 }
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
