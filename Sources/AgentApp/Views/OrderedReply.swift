import SwiftUI

/// P43: an assistant reply drawn in the order it happened — text, the steps it ran, the text after them. A reply without
/// ordered steps (no steps, or saved before P43) is its text with one Steps row below, as before.
struct OrderedReply: View {
    @ObservedObject var message: ChatMessage
    var actionTarget: ConversationActionTarget?
    var stepsExpanded = false
    /// P41: renders open the bot-msg replies too.
    var botRepliesExpanded = false

    var body: some View {
        if let segments = ReplyLayout.segments(content: message.content, activity: message.activity) {
            let bases = Self.indexBases(segments)
            ForEach(Array(segments.enumerated()), id: \.offset) { position, segment in
                switch segment {
                case .text(let text): MarkdownContent(message: message, actionTarget: actionTarget, text: text, indexBase: bases[position])
                case .steps(let range): ActivityRow(message: message, expanded: stepsExpanded, range: range, live: position == segments.count - 1, repliesExpanded: botRepliesExpanded)
                }
            }
            // Text arrived after the last steps: the live line moves below it.
            if case .text? = segments.last, message.isStreaming { ActivityRow(message: message, headerOnly: true) }
        } else {
            MarkdownContent(message: message, actionTarget: actionTarget)
            // P29: one row while streaming and after, so an open row stays open when the turn ends.
            ActivityRow(message: message, expanded: stepsExpanded, repliesExpanded: botRepliesExpanded)
        }
    }

    /// The card index each text segment starts at, so cards keep distinct indexes across segments.
    static func indexBases(_ segments: [ReplySegment]) -> [Int] {
        var next = 0
        return segments.map { segment in
            defer { if case .text(let text) = segment { next += ChatCardParser.parse(SwarmhubBlock.visibleText(text)).count } }
            return next
        }
    }
}
