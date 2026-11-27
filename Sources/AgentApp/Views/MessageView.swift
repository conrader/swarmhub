import SwiftUI

struct MessageView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("accent") private var accent = AppTheme.defaultAccent
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
    private var userBubbleFill: AnyShapeStyle {
        accent == "Blue" ? AnyShapeStyle(AppColor.adaptive(Palette.userBubble)) : AnyShapeStyle(TintShapeStyle().opacity(0.16))
    }

    var body: some View { row }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            if mine { Spacer(minLength: 110) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 7) {
                if let quote = message.displayedChoiceQuote ?? repliedMessage.map(SidebarFragment.preview) {
                    HStack(spacing: 5) {
                        Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 24)
                        Text(quote).lineLimit(2)
                    }.font(.caption).foregroundStyle(.secondary).help(quote)
                }
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
                if let title = message.metadata["herdrExchangeTitle"] {
                    DisclosureGroup(title) { Text(message.content).textSelection(.enabled) }.font(.callout)
                } else { content }
                if let outcome = message.metadata[GoalKey.outcome] {
                    Text("Goal step · " + outcome.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption).foregroundStyle(.secondary)
                        .help(message.metadata[GoalKey.evidence] ?? outcome)
                }
                if let results = message.publishedResults { HerdrReplyFiles(messageID: message.id, results: results) }
                if message.turnState == .finished, let summary = message.runSummary {
                    Text(summary.line).font(.caption).foregroundStyle(.secondary)
                        .help("Elapsed time and tool calls reported to SwarmHub. The model label comes from this reply’s session.")
                }
                if let claim = store.waitingDirectClaim(for: message) {
                    Button("Cancel queued send") { store.cancelQueuedSend(claim) }
                        .controlSize(.small)
                } else if store.canSendAsNextMessage(message) {
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
        HStack(spacing: 4) {
            Button { showingReactions.toggle() } label: { Image(systemName: "face.smiling") }.help("Tapback")
            Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") }.help("Reply")
            if message.role == .assistant && message.presentation == .text { Button { copyToPasteboard(SwarmhubBlock.visibleText(message.finalText)) } label: { Image(systemName: "doc.on.doc") }.help("Copy reply") }
        }.buttonStyle(MessageActionStyle())
            .popover(isPresented: $showingReactions) {
                HStack { ForEach(Self.tapbacks, id: \.self) { emoji in Button(emoji) { store.toggleReaction(emoji, on: message); showingReactions = false }.buttonStyle(.plain).padding(4).background(message.reactions.contains(emoji) ? AnyShapeStyle(TintShapeStyle().opacity(0.3)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    .overlay { if message.reactions.contains(emoji) { RoundedRectangle(cornerRadius: 6).strokeBorder(.tint, lineWidth: 1.5) } }
                    .accessibilityAddTraits(message.reactions.contains(emoji) ? .isSelected : []) } }.padding(10)
            }
    }

    @ViewBuilder private var content: some View {
        if let passedOn = store.herdrPassedOnRow(message) {
            // A message between bots, on either side of it: one folded row in the colour of the bot whose words it is.
            PassedOnCard(row: passedOn)
        } else if message.role == .system {
            Label { literalBody } icon: { Image(systemName: message.metadata[TurnKey.tone] == "warning" ? "exclamationmark.triangle" : message.metadata[TurnWaitCopy.key] == "line" ? "clock" : "checkmark.circle") }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if let intro = message.metadata[HerdrIntro.Key.kind] {
            // The note that asks the main bot to introduce itself: one line says so, the note is the agent's to read.
            Label(HerdrIntro.caption(bot: store.selectedBot?.name ?? "your bot", again: intro == HerdrIntro.again), systemImage: "hand.wave").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
        } else if message.role == .user, message.metadata[GoalKey.attempt] != nil {
            Label { literalBody } icon: { Image(systemName: "scope") }.font(.caption).foregroundStyle(.secondary)
        } else if message.role == .user {
            if let helper = message.metadata[HelperGuidanceKey.helper] {
                Label("Guidance for " + helper, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
            }
            if !message.content.isEmpty {
                UserMessageText(source: message.content).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)

                    .background(message.isSteer || message.isCorrection ? AnyShapeStyle(AppColor.card) : userBubbleFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .background(AppColor.chat, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay { if message.isSteer || message.isCorrection { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
            }
        } else {
            OrderedReply(message: message, actionTarget: actionTarget, stepsExpanded: stepsExpanded)
        }
    }
    private var literalBody: some View {
        TranscriptRunView(run: .init(value: AttributedString(message.content), offset: 0), style: .caption)
    }
}

/// The small actions under a message (tapback, reply, copy): symbols in a colour that reads at 4.5:1 on the chat
/// (they were drawn in the faintest text colour), each on a round ground that shows under the pointer.
struct MessageActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Mark(configuration: configuration) }

    private struct Mark: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(AppColor.mark))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0)))
                .contentShape(Circle()).onHover { hovering = $0 }
        }
    }
}

extension AppStore {
    /// Materialize an unmounted row only when Copy or Select All needs its text.
    /// Disclosure labels, card actions and the prompts behind them have their own UI.
    func transcriptBody(_ message: ChatMessage) -> String {
        guard message.metadata["herdrExchangeTitle"] == nil, herdrPassedOnRow(message) == nil else { return "" }
        if message.role != .system, message.metadata[HerdrIntro.Key.kind] != nil { return "" }
        switch message.role {
        case .system: return message.content
        case .user:
            if message.metadata[GoalKey.attempt] != nil { return message.content }
            return TranscriptText(user: message.content).string
        case .assistant:
            let segments = ReplyLayout.segments(content: message.content, activity: message.activity)
            return TranscriptText(reply: message.content, segments: segments).string
        }
    }
}
