import SwiftUI

/// Queue markers stay in the saved transcript for delivery and recovery. Present their reason once per conversation.
struct ChatQueuePresentation {
    var transcript: [ChatMessage] = []
    var waiting: [ChatMessage] = []
    var reason: String?

    init(_ messages: [ChatMessage]) {
        transcript.reserveCapacity(messages.count)
        var previousWasWaiting = false
        for message in messages {
            if previousWasWaiting, message.role == .system, message.metadata[TurnWaitCopy.key] == "line" {
                if waiting.count == 1, message.content != TurnWaitCopy.behind {
                    reason = message.content
                }
                previousWasWaiting = false
                continue
            }
            previousWasWaiting = message.isQueuedUserMessage
            if previousWasWaiting { waiting.append(message) }
            if !message.isSilent { transcript.append(message) }
        }
    }
}

extension ChatMessage {
    var isQueuedUserMessage: Bool { role == .user && metadata[TurnWaitCopy.key] == "waiting" }
}

struct ChatQueueSummary: View {
    @EnvironmentObject private var store: AppStore
    let queue: ChatQueuePresentation
    @State private var expanded = false

    var body: some View {
        if !queue.waiting.isEmpty {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                    Text("\(queue.waiting.count) queued").fontWeight(.semibold)
                    if let reason = queue.reason {
                        Text(reason).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Image(systemName: "chevron.up").imageScale(.small)
                }
                .font(.caption).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("View queued messages")
            .padding(.horizontal, 20).padding(.vertical, 4)
            .frame(maxWidth: 720, alignment: .leading)
            .popover(isPresented: $expanded, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Queued messages").font(.headline)
                    if let reason = queue.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(queue.waiting) { message in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(verbatim: SidebarFragment.preview(message))
                                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                                    if let claim = store.waitingDirectClaim(for: message) {
                                        Button("Cancel") { store.cancelQueuedSend(claim) }
                                            .controlSize(.small).accessibilityLabel("Cancel queued send")
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 240).fixedSize(horizontal: false, vertical: true)
                }.padding(14).frame(width: 320)
            }
            .onDisappear { expanded = false }
        }
    }
}
