import SwiftUI

/// P50: what one chat transcript shows, told to `ChatScrollModel`. Rows report appearing and disappearing (a lazy stack
/// lays out a little beyond the visible area, so "at the bottom" means within a few rows of it); the topmost shown row is
/// the saved position. Not observed: it never redraws the transcript.
@MainActor final class ChatViewport {
    private(set) var conversationID: UUID?
    private var order: [UUID] = [], showing: UUID?
    private var visible: Set<UUID> = [], bottomVisible = false
    private weak var model: ChatScrollModel?

    private var top: UUID? { order.first { visible.contains($0) } }

    /// Every body pass: the conversation shown and its message ids, top to bottom. Another conversation starts clean and
    /// reports nothing until `open` (the transcript carries `.id(conversation)`, so its rows and marker appear anew).
    func show(_ id: UUID, order: [UUID]) {
        self.order = order
        guard showing != id else { return }
        showing = id; conversationID = nil; visible = []; bottomVisible = false
    }

    func row(_ id: UUID, visible shown: Bool) {
        if shown { visible.insert(id) } else { visible.remove(id) }
        report()
    }
    /// The marker of `conversation` (an old transcript's marker may leave after the new one arrived).
    func bottom(_ conversation: UUID, visible shown: Bool) {
        guard conversation == showing else { return }
        bottomVisible = shown; report()
    }

    /// Opens `id` where it was left (or at the newest), scrolling again while the lazy rows lay out.
    func open(_ id: UUID, model: ChatScrollModel, proxy: ScrollViewProxy) async {
        guard showing == id else { return }
        conversationID = id; self.model = model
        let target = model.open(id, shown: order)
        for _ in 0..<3 {
            await Task.yield()
            switch target {
            case .newest: proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
            case .message(let message): proxy.scrollTo(message, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard showing == id else { model.opened(id, top: nil, atBottom: false); return }
        model.opened(id, top: top, atBottom: bottomVisible)
    }

    /// New rows: follow them only at the bottom, else count them for the button.
    func arrived(_ count: Int, proxy: ScrollViewProxy) {
        guard let id = conversationID, let model, count > 0 else { return }
        if model.arrived(id, count: count) { proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom) }
    }
    /// Streaming text in the newest row.
    func grew(proxy: ScrollViewProxy) {
        guard let id = conversationID, let model, model.follows(id) else { return }
        proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
    }

    private func report() {
        guard let id = conversationID else { return }
        model?.saw(id, top: top, atBottom: bottomVisible)
    }
}

enum ChatScrollAnchor { static let bottom = "bottom" }

extension View {
    /// P50: a transcript row reports whether it is laid out.
    func chatRow(_ id: UUID, in viewport: ChatViewport) -> some View {
        onAppear { viewport.row(id, visible: true) }.onDisappear { viewport.row(id, visible: false) }
    }
}

/// The transcript's end: scroll anchor and bottom detector.
struct ChatBottomMarker: View {
    let viewport: ChatViewport; let conversationID: UUID
    var body: some View {
        Color.clear.frame(height: 1).id(ChatScrollAnchor.bottom)
            .onAppear { viewport.bottom(conversationID, visible: true) }.onDisappear { viewport.bottom(conversationID, visible: false) }
    }
}

/// "Jump to latest" (· N new), bottom centre above the composer, while the transcript is away from the newest.
struct JumpToLatestButton: View {
    @ObservedObject var scroll: ChatScrollModel; let conversationID: UUID; let proxy: ScrollViewProxy
    var body: some View {
        if let label = scroll.jumpLabel(conversationID) {
            Button {
                scroll.toBottom(conversationID)
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom) }
            } label: {
                Label(label, systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(AppColor.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .buttonStyle(.plain).padding(.bottom, 12)
            .accessibilityLabel("Jump to latest message")
            .help("Jump to latest message")
        }
    }
}
