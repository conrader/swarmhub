import SwiftUI

/// P43: an assistant reply drawn in the order it happened — text, the steps it ran, the text after them. A reply without
/// ordered steps (no steps, or saved before P43) is its text with one Steps row below, as before.
struct OrderedReply: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var actionTarget: ConversationActionTarget?
    var stepsExpanded = false
    /// P41: renders open the bot-msg replies too.

    var body: some View {
        if let segments = ReplyLayout.segments(content: message.content, activity: message.activity) {
            let indexes = ReplyLayout.blockIndexes(segments, content: message.content)
            ForEach(Array(segments.enumerated()), id: \.offset) { position, segment in
                switch segment {
                case .text(let text): MarkdownContent(message: message, actionTarget: actionTarget, text: text, indexes: indexes[position])
                case .steps(let range): ActivityRow(message: message, expanded: stepsExpanded, range: range, live: position == segments.count - 1)
                }
            }
            // Text arrived after the last steps: the live line moves below it.
            if case .text? = segments.last, message.isStreaming { ActivityRow(message: message, headerOnly: true) }
        } else {
            MarkdownContent(message: message, actionTarget: actionTarget)
            // P29: one row while streaming and after, so an open row stays open when the turn ends.
            ActivityRow(message: message, expanded: stepsExpanded)
        }
        if let actionTarget, message.metadata[ChatChoiceInference.answerKey] == nil,
           store.canAnswerChoice(message, target: actionTarget), let options = ChatChoiceInference.options(in: message.content) {
            ChoicesCard(prompt: "", options: options, picked: nil, enabled: true) { answer in
                store.answerInferredChoice(target: actionTarget, source: message, expected: options, answer: answer)
            }
        }
    }
}
