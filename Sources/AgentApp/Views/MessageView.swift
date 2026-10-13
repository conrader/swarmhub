import SwiftUI

struct MessageView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    let repliedMessage: ChatMessage?; let thread: ChatThread?; let canThread: Bool
    let reply: () -> Void; let openThread: () -> Void
    @State private var showingReactions = false
    static let tapbacks = ["👍", "❤️", "😂", "‼️", "?"]
    init(message: ChatMessage, repliedMessage: ChatMessage? = nil, thread: ChatThread? = nil, canThread: Bool = false, reply: @escaping () -> Void = {}, openThread: @escaping () -> Void = {}) {
        self.message = message; self.repliedMessage = repliedMessage; self.thread = thread; self.canThread = canThread; self.reply = reply; self.openThread = openThread
    }
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 110) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                if let repliedMessage { HStack(spacing: 5) { Rectangle().fill(.secondary.opacity(0.35)).frame(width: 2, height: 24); Text(repliedMessage.content).lineLimit(1) }.font(.caption).foregroundStyle(.secondary) }
                if message.isSteer {
                    Label(message.metadata["steer"] == "failed" ? "Steer not delivered" : "Steered the running turn", systemImage: "arrow.turn.down.right").font(.caption2).foregroundStyle(.secondary)
                }
                if !message.attachments.isEmpty { AttachmentThumbnails(attachments: message.attachments) }
                content
                if !message.reactions.isEmpty {
                    HStack(spacing: 3) { ForEach(message.reactions, id: \.self) { emoji in Button { store.toggleReaction(emoji, on: message) } label: { Text(emoji).font(.caption).padding(4).background(AppColor.card, in: Capsule()).overlay(Capsule().stroke(AppColor.separator)) }.buttonStyle(.plain).help("Remove tapback") } }
                }
                if message.role != .system && !message.isStreaming { actions }
                if let thread { ThreadLink(thread: thread, open: openThread) }
            }
            if message.role != .user { Spacer(minLength: 80) }
        }.padding(.horizontal, 28).padding(.vertical, 10)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button { showingReactions.toggle() } label: { Image(systemName: "face.smiling") }.help("Tapback")
            Button(action: reply) { Image(systemName: "arrowshape.turn.up.left") }.help("Reply")
            if canThread && thread == nil && message.role == .assistant { Button(action: openThread) { Image(systemName: "bubble.left.and.text.bubble.right") }.help("Reply in thread") }
        }.buttonStyle(.plain).foregroundStyle(.tertiary).font(.caption)
            .popover(isPresented: $showingReactions) {
                HStack { ForEach(Self.tapbacks, id: \.self) { emoji in Button(emoji) { store.toggleReaction(emoji, on: message); showingReactions = false }.buttonStyle(.plain).padding(3).background(message.reactions.contains(emoji) ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 5)) } }.padding(10)
            }
    }

    @ViewBuilder private var content: some View {
        switch message.presentation {
        case .draftEmail: DraftEmailCard(message: message)
        case .options: OptionCard(message: message)
        case .attachment: AttachmentCard(message: message)
        case .image: ImageCard(message: message)
        case .links: LegacyLinkPills(message: message)
        case .voiceMemo: VoiceMemoCard(message: message)
        case .delegation: DelegationCard(message: message)
        case .routineResult: RoutineResultCard(message: message)
        case .text:
            if message.role == .system {
                Label(message.content, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else if message.role == .user {
                if !message.content.isEmpty {
                    Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3).padding(.horizontal, 14).padding(.vertical, 10)
                        .background(message.isSteer ? AppColor.card : AppColor.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay { if message.isSteer { RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppColor.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) } }
                }
            } else {
                MarkdownContent(message: message)
                if message.isStreaming { ProgressView().controlSize(.mini) }
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
