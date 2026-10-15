import Foundation

/// P43: the box's tool calls become the reply's steps, at the place in the text where they happened (assistant text,
/// tool calls, tool results, the final assistant text → text, steps, text).
extension HistoryReconciler.ServerTurn {
    /// The steps of this turn with their offsets into `replyText`; nil when the turn called no tool.
    var activity: ToolActivity? {
        var activity = ToolActivity(); var text = ""
        for row in rows {
            if !row.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text += (text.isEmpty ? "" : "\n\n") + row.content }
            let time = row.createdAt ?? .distantPast
            for (index, name) in row.tools.enumerated() where ToolActivity.isShown(name) {
                // P42: what the call ran on, when the read kept it (live work); reconcile reads leave it out.
                let preview = index < row.toolPreviews.count ? row.toolPreviews[index] : nil
                activity.steps.append(ToolStep(name: name, preview: preview, startedAt: time, finishedAt: time, textOffset: text.utf16.count)); activity.total += 1
            }
        }
        guard activity.total > 0 else { return nil }
        if activity.steps.count > ToolActivity.limit { activity.steps.removeFirst(activity.steps.count - ToolActivity.limit) }
        activity.endedAt = activity.steps.last?.finishedAt
        return activity
    }
}

extension HistoryReconciler {
    /// Moves each step's offset from `source` to `target`, which holds the same text up to whitespace (`extend`).
    static func placed(_ activity: ToolActivity, from source: String, in target: String) -> ToolActivity {
        var activity = activity
        for index in activity.steps.indices {
            guard let offset = activity.steps[index].textOffset else { continue }
            activity.steps[index].textOffset = mapOffset(offset, from: source, to: target)
        }
        return activity
    }

    /// The UTF-16 offset in `target` after as many non-space characters as `source` has before `offset`.
    static func mapOffset(_ offset: Int, from source: String, to target: String) -> Int {
        let utf16 = source.utf16
        let end = utf16.index(utf16.startIndex, offsetBy: min(max(0, offset), utf16.count))
        let need = nonSpaceCount(String(source[..<end]))
        guard need > 0 else { return 0 }
        var seen = 0
        for index in target.unicodeScalars.indices where !CharacterSet.whitespacesAndNewlines.contains(target.unicodeScalars[index]) {
            seen += 1
            if seen == need { return target.utf16.distance(from: target.utf16.startIndex, to: target.unicodeScalars.index(after: index)) }
        }
        return target.utf16.count
    }
}
