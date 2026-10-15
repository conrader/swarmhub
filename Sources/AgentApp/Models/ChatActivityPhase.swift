import Foundation

/// Activity of a live reply, inferred from text arrival and tool lifecycle events.
enum ChatActivityPhase: String, CaseIterable, Sendable {
    case thinking = "Thinking", typing = "Typing", working = "Working"
    var label: String { rawValue + "…" }

    /// Allow short gaps between network chunks without making the label flicker.
    static let textPause: TimeInterval = 2

    static func current(_ activity: ToolActivity?, lastText: Date?, now: Date) -> Self {
        let lastToolEvent = activity?.steps.map { max($0.startedAt, $0.finishedAt ?? $0.startedAt) }.max()
        if let lastText, max(0, now.timeIntervalSince(lastText)) <= textPause,
           lastToolEvent.map({ lastText >= $0 }) ?? true {
            return .typing
        }
        return activity?.current == nil ? .thinking : .working
    }
}
