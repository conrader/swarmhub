import SwiftUI

struct MessageView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    let repliedMessage: ChatMessage?; let thread: ChatThread?; let canThread: Bool
    /// P13 Part D: the Coding model "Code in thread" locks a fork to; nil hides the button.
    let codingModel: String?
    let reply: () -> Void; let openThread: () -> Void; let codeInThread: () -> Void
    /// P27: renders open the steps row.
    var stepsExpanded = false
    /// P41: renders open the bot-msg replies on those steps.
    var botRepliesExpanded = false
    /// P38: the chat its cards answer into.
    let actionTarget: ConversationActionTarget?
    @State private var showingReactions = false
    static let tapbacks = ["👍", "❤️", "😂", "‼️", "?"]
    init(message: ChatMessage, repliedMessage: ChatMessage? = nil, thread: ChatThread? = nil, canThread: Bool = false, codingModel: String? = nil,
         actionTarget: ConversationActionTarget? = nil, reply: @escaping () -> Void = {}, openThread: @escaping () -> Void = {}, codeInThread: @escaping () -> Void = {}) {
        self.actionTarget = actionTarget; self.message = message; self.repliedMessage = repliedMessage; self.thread = thread; self.canThread = canThread; self.codingModel = codingModel
        self.reply = reply; self.openThread = openThread; self.codeInThread = codeInThread
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 110) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                if let repliedMessage { HStack(spacing: 5) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 24); Text(SwarmhubBlock.visibleText(repliedMessage.content)).lineLimit(1) }.font(.caption).foregroundStyle(.secondary) }
                if let caption = SteerCopy.caption(message) {
                    Label(caption, systemImage: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                }
                if !message.attachments.isEmpty { AttachmentThumbnails(attachments: message.attachments) }
                content
                if store.canSendAsNextMessage(message) {
                    Button(SteerCopy.sendAsNext) { store.sendAsNextMessage(message) }
                        .controlSize(.small).help("Sends this text as a normal message once the current answer ends")
                }
                if !message.reactions.isEmpty {
                    HStack(spacing: 3) { ForEach(message.reactions, id: \.self) { emoji in Button { store.toggleReaction(emoji, on: message) } label: { Text(emoji).font(.caption).padding(4).background(AppColor.card, in: Capsule()).overlay(Capsule().stroke(AppColor.separator)) }.buttonStyle(.plain).help("Remove tapback") } }
                }
                if TurnStateFooter.isShown(for: message) { TurnStateFooter(message: message) }
                if message.role != .system && !message.isStreaming && !isEmptyReply { actions }
                if let thread { ThreadLink(thread: thread, open: openThread) }
            }
            if message.role != .user { Spacer(minLength: 80) }
        }.padding(.horizontal, 28).padding(.vertical, 10)
    }

    /// P16: an empty assistant text row (not sent, stopped before a token) offers no tapback or reply.
    private var isEmptyReply: Bool {
        message.role == .assistant && message.presentation == .text && message.attachments.isEmpty && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { showingReactions.toggle() } label: { Image(systemName: "face.smiling") }.help("Tapback")
            Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") }.help("Reply")
            if message.role == .assistant && message.presentation == .text { Button { copyToPasteboard(SwarmhubBlock.visibleText(message.finalText)) } label: { Image(systemName: "doc.on.doc") }.help("Copy reply") }
            if canThread && thread == nil && message.role == .assistant { Button(action: openThread) { Image(systemName: "bubble.left.and.text.bubble.right") }.help("Reply in thread") }
            if canThread && thread == nil && message.role == .assistant, let codingModel {
                Button(action: codeInThread) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .help("Code in thread\n" + ModelRolesModel.codingThreadHelp(codingModel)).accessibilityLabel("Code in thread on \(codingModel)")
            }
        }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption)
            .popover(isPresented: $showingReactions) {
                HStack { ForEach(Self.tapbacks, id: \.self) { emoji in Button(emoji) { store.toggleReaction(emoji, on: message); showingReactions = false }.buttonStyle(.plain).padding(3).background(message.reactions.contains(emoji) ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 5)) } }.padding(10)
            }
    }

    @ViewBuilder private var content: some View {
        switch message.presentation {
        case .delegation: DelegationCard(message: message)
        case .routineResult: RoutineResultCard(message: message)
        case .botMessage: BotArrivalLine(message: message)
        case .approvalDecision: ApprovalDecisionLine(message: message)
        case .review: ReviewCard(message: message)
        case .text:
            if message.role == .system {
                Label(message.content, systemImage: message.metadata[TurnKey.tone] == "warning" ? "exclamationmark.triangle" : message.metadata[TurnWaitCopy.key] == "line" ? "clock" : "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if message.role == .user {
                if !message.content.isEmpty {
                    Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(message.isSteer || message.isCorrection ? AppColor.card : AppColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay { if message.isSteer || message.isCorrection { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
                }
            } else {
                OrderedReply(message: message, actionTarget: actionTarget, stepsExpanded: stepsExpanded, botRepliesExpanded: botRepliesExpanded)
                BotMessageChipsRow(message: message)
            }
        }
    }
    private var markdown: AttributedString { (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full))) ?? AttributedString(message.content) }
}

/// "3 replies" under the message a thread was started from.
private struct ThreadLink: View {
    @ObservedObject var thread: ChatThread; let open: () -> Void
    var body: some View {
        Button(action: open) {
            Label(thread.replyCount == 0 ? "Thread" : "\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies")", systemImage: "arrow.turn.down.right")
                .font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 4).background(AppColor.card, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5))
        }.buttonStyle(.plain).help("Open thread")
    }
}
