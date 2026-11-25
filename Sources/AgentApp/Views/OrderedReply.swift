import SwiftUI

/// P43: an assistant reply drawn in the order it happened — text, the steps it ran, the text after them. A reply without
/// ordered steps (no steps, or saved before P43) is its text with one Steps row below, as before.
struct OrderedReply: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.transcriptSelection) private var selection
    @ObservedObject var message: ChatMessage
    var actionTarget: ConversationActionTarget?
    var stepsExpanded = false
    /// P41: renders open the bot-msg replies too.

    var body: some View {
        let segments = ReplyLayout.segments(content: message.content, activity: message.activity)
        let projection = TranscriptText(reply: message.content, segments: segments)
        let _ = selection?.rendered(.message(message.id), text: projection.string)
        if let segments {
            let indexes = ReplyLayout.blockIndexes(segments, content: message.content)
            ForEach(Array(segments.enumerated()), id: \.offset) { position, segment in
                switch segment {
                case .text(let text): MarkdownContent(message: message, actionTarget: actionTarget, text: text, indexes: indexes[position], renderedBlocks: projection.parts[position])
                case .steps(let range): ActivityRow(message: message, expanded: stepsExpanded, range: range, live: position == segments.count - 1)
                }
            }
            // Text arrived after the last steps: the live line moves below it.
            if case .text? = segments.last, message.isStreaming { ActivityRow(message: message, headerOnly: true) }
        } else {
            MarkdownContent(message: message, actionTarget: actionTarget, renderedBlocks: projection.parts[0])
            // P29: one row while streaming and after, so an open row stays open when the turn ends.
            ActivityRow(message: message, expanded: stepsExpanded)
        }
        let shownContent = message.content
        if let actionTarget,
           let options = ChatChoiceInference.options(in: shownContent) {
            let status = store.choiceStatus(message, target: actionTarget, key: ChatChoiceInference.answerKey,
                                            binary: ChoiceReply.isYesNo(options.map(\.label)))
            if status.enabled || status.picked != nil {
                ChoicesCard(prompt: "", options: options, picked: status.picked, enabled: status.enabled) { answer in
                    store.answerInferredChoice(target: actionTarget, source: message, shownContent: shownContent, answer: answer)
                }
            }
        }
    }
}
