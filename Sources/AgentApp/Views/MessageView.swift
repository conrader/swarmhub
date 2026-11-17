import SwiftUI

struct MessageView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    let repliedMessage: ChatMessage?
    let reply: () -> Void
    /// Renders open the steps row.
    var stepsExpanded = false
    /// The chat its cards answer into.
    let actionTarget: ConversationActionTarget?
    @State private var showingReactions = false
    static let tapbacks = ["👍", "❤️", "😂", "‼️", "?"]
    /// Set on the reply that opens a run of the bot's rows: its face and name go above it, in its colour.
    var author: Bot? = nil
    init(message: ChatMessage, repliedMessage: ChatMessage? = nil, actionTarget: ConversationActionTarget? = nil, reply: @escaping () -> Void = {}, author: Bot? = nil) {
        self.actionTarget = actionTarget; self.message = message; self.repliedMessage = repliedMessage; self.reply = reply; self.author = author
    }
    var body: some View { row }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 110) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 7) {
                if let repliedMessage { HStack(spacing: 5) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 24); Text(store.displayLine(repliedMessage)).lineLimit(1) }.font(.caption).foregroundStyle(.secondary) }
                if let caption = SteerCopy.caption(message) {
                    Label(caption, systemImage: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                }
                if let author, message.role == .assistant {
                    HStack(spacing: 6) {
                        BotAvatar(bot: author, size: 18)
                        Text(author.name).font(.caption.weight(.semibold)).foregroundStyle(author.tintInk)
                    }.accessibilityElement(children: .combine).accessibilityLabel(author.name)
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
                if message.role != .system && !message.isStreaming && !isEmptyReply && !store.isAppWritten(message) { actions }
            }
            if !mine { Spacer(minLength: 80) }
        }.padding(.horizontal, 28).padding(.vertical, 10)
    }

    /// The person's own message sits on the right; what the app wrote for the agent does not.
    private var mine: Bool { message.role == .user && !store.isAppWritten(message) }

    /// An empty assistant text row (not sent, stopped before a token) offers no tapback or reply.
    private var isEmptyReply: Bool {
        message.role == .assistant && message.presentation == .text && message.attachments.isEmpty && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { showingReactions.toggle() } label: { Image(systemName: "face.smiling") }.help("Tapback")
            Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") }.help("Reply")
            if message.role == .assistant && message.presentation == .text { Button { copyToPasteboard(SwarmhubBlock.visibleText(message.finalText)) } label: { Image(systemName: "doc.on.doc") }.help("Copy reply") }
        }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption)
            .popover(isPresented: $showingReactions) {
                HStack { ForEach(Self.tapbacks, id: \.self) { emoji in Button(emoji) { store.toggleReaction(emoji, on: message); showingReactions = false }.buttonStyle(.plain).padding(3).background(message.reactions.contains(emoji) ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 5)) } }.padding(10)
            }
    }

    @ViewBuilder private var content: some View {
        if let passedOn = store.herdrPassedOnRow(message) {
            // A message between bots, on either side of it: one folded row in the colour of the bot whose words it is.
            PassedOnCard(row: passedOn)
        } else if message.role == .system {
            Label(message.content, systemImage: message.metadata[TurnKey.tone] == "warning" ? "exclamationmark.triangle" : message.metadata[TurnWaitCopy.key] == "line" ? "clock" : "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4).textSelection(.enabled)
        } else if let intro = message.metadata[HerdrIntro.Key.kind] {
            // The note that asks the main bot to introduce itself: one line says so, the note is the agent's to read.
            Label(HerdrIntro.caption(bot: store.selectedBot?.name ?? "your bot", again: intro == HerdrIntro.again), systemImage: "hand.wave").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if message.role == .user {
            if !message.content.isEmpty {
                Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)
                    // The person's own words sit on a wash of the accent, so the two sides of a chat differ by colour, not only by side.
                    .background(message.isSteer || message.isCorrection ? AnyShapeStyle(AppColor.card) : AnyShapeStyle(TintShapeStyle().opacity(0.16)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .background(AppColor.chat, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { if message.isSteer || message.isCorrection { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
            }
        } else {
            OrderedReply(message: message, actionTarget: actionTarget, stepsExpanded: stepsExpanded)
        }
    }
    private var markdown: AttributedString { (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full))) ?? AttributedString(message.content) }
}
