import SwiftUI

/// Size the rows around the destination before scrolling. A lazy stack estimates the height
/// of unmeasured rich-text rows, which can leave a restored offset outside the actual rows.
@MainActor final class ChatViewport: ObservableObject {
    static let pageSize = 24
    enum Destination: Equatable { case latest, row(UUID, UnitPoint), archive(String) }
    private(set) var archivePage: GrokHistoryPage?
    private(set) var revision = 0
    private(set) var destination: Destination = .latest
    private(set) var range = 0..<0
    private var conversation: UUID?
    private var restoringArchive: String?
    private var order: [UUID] = []
    private var settled = false
    private var waitingForRow: UUID?
    private var visible = ChatVisibleRows()
    private weak var model: ChatScrollModel?

    func show(_ id: UUID, order: [UUID], model: ChatScrollModel) {
        if conversation != id {
            self.order = order
            self.model = model
            conversation = id
            restoringArchive = model.archivePositions[id]
            let saved = model.positions[id].flatMap { order.firstIndex(of: $0) }
            destination = saved.map { .row(order[$0], .top) } ?? .latest
            range = page(around: saved ?? order.count)
        } else if self.order != order {
            let oldCount = range.count
            let first = range.first.map { self.order[$0] }
            self.order = order
            let start = first.flatMap { order.firstIndex(of: $0) } ?? min(range.lowerBound, order.count)
            // Preserve the reading page through a batch append or removal; following the tail is handled by arrived().
            range = start..<min(start + max(oldCount, Self.pageSize), order.count)
        }
    }

    private func page(around index: Int) -> Range<Int> {
        let start = max(0, min(index - Self.pageSize / 2, order.count - Self.pageSize))
        return start..<min(order.count, start + Self.pageSize)
    }

    var hasEarlier: Bool { range.lowerBound > 0 }
    var hasLater: Bool { range.upperBound < order.count }

    func earlier() {
        guard hasEarlier else { return }
        let edge = range.lowerBound
        let start = max(0, edge - Self.pageSize + 1)
        move(to: .row(order[edge], .bottom), range: start..<(edge + 1))
    }

    func later() {
        guard hasLater else { return }
        let start = range.upperBound - 1
        move(to: .row(order[start], .top), range: start..<min(order.count, start + Self.pageSize))
    }

    /// Keep the same boundary row under the pointer when wheel/trackpad scrolling crosses a page.
    func scrollPastEdge(delta: CGFloat) -> Bool {
        guard settled, visible.height > 0 else { return false }
        if delta > 0, hasEarlier, let top = visible.start, top >= -2 {
            let edge = range.lowerBound
            let start = max(0, edge - Self.pageSize / 2)
            move(to: .row(order[edge], .top), range: start..<min(order.count, start + Self.pageSize))
            return true
        }
        if delta < 0, hasLater, let bottom = visible.bottom, bottom <= visible.height + 2 {
            let edge = range.upperBound - 1
            let next = page(around: edge + 1)
            move(to: .row(order[edge], .bottom), range: next)
            return true
        }
        return false
    }

    func reveal(_ request: ChatMessageLocation?, in store: AppStore) async {
        guard let conversation,
              let target = request ?? restoringArchive.map({ ChatMessageLocation(conversation: conversation, imported: $0) }),
              target.conversation == conversation else { return }
        switch target.row {
        case .live(let id): jump(to: id)
        case .imported(let key):
            let archive = store.grokHistory
            let page = await GrokHistoryPage.containing(key, cached: archive.loaded[target.conversation], url: archive.fileURL(for: target.conversation))
            guard !Task.isCancelled, request == store.scrollTarget, target.conversation == self.conversation,
                  request != nil || restoringArchive == key else { return }
            if let page { showArchive(page) }
            else {
                latest()
                if request != nil { store.errorMessage = "This message is no longer in the imported history." }
            }
        }
        if request != nil { store.scrollTarget = nil }
    }

    func showArchive(_ page: GrokHistoryPage) {
        guard let conversation else { return }
        model?.readingArchive(conversation, key: page.key)
        move(to: .archive(page.key), range: self.page(around: 0), archive: page)
    }

    func jump(to message: UUID) {
        guard let i = order.firstIndex(of: message) else { return }
        move(to: .row(message, .center), range: page(around: i))
    }

    func latest() {
        guard let conversation else { return }
        model?.toBottom(conversation)
        move(to: .latest, range: page(around: order.count))
    }

    private func move(to target: Destination, range: Range<Int>, archive: GrokHistoryPage? = nil) {
        objectWillChange.send()
        restoringArchive = nil
        settled = false
        waitingForRow = nil
        if self.range != range || archivePage?.key != archive?.key { visible = ChatVisibleRows() }
        archivePage = archive
        destination = target
        self.range = range
        revision += 1
    }

    func position(proxy: ScrollViewProxy) async {
        let request = revision
        await Task.yield()
        guard !Task.isCancelled, request == revision, restoringArchive == nil else { return }
        if request == 0, let conversation { _ = model?.open(conversation, shown: order) }
        switch destination {
        case .latest: proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
        case let .row(message, anchor):
            // SwiftUI can start the task before the destination row has joined the scroll view.
            guard visible.height > 0, visible.rows[message] != nil else {
                waitingForRow = message
                return
            }
            proxy.scrollTo(message, anchor: anchor)
        case let .archive(key): proxy.scrollTo(ChatScrollAnchor.imported(key), anchor: .center)
        }
        await Task.yield()
        guard !Task.isCancelled, request == revision else { return }
        settled = true
        if let conversation { model?.opened(conversation, top: nil, atBottom: false) }
        report()
    }

    func measured(_ frames: ChatVisibleRows) {
        visible = frames
        if let waitingForRow, frames.height > 0, frames.rows[waitingForRow] != nil {
            self.waitingForRow = nil
            objectWillChange.send()
            revision += 1
        } else if settled { report() }
    }

    private func report() {
        guard let conversation, visible.height > 0 else { return }
        if let page = archivePage, let focus = visible.archiveFocus, focus.maxY > 0 && focus.minY < visible.height {
            model?.readingArchive(conversation, key: page.key)
            return
        }
        let top = range.lazy.map { self.order[$0] }.first { id in
            guard let frame = visible.rows[id] else { return false }
            return frame.maxY > 0 && frame.minY < visible.height
        }
        let bottom = !hasLater && visible.bottom.map { $0 <= visible.height + 2 && $0 >= 0 } == true
        model?.saw(conversation, top: top, atBottom: bottom)
    }

    func arrived(_ count: Int, follow: Bool = true) {
        guard let conversation, count > 0 else { return }
        if model?.arrived(conversation, count: count) == true, follow { latest() }
    }

    func grew(proxy: ScrollViewProxy) {
        guard settled, let conversation, model?.follows(conversation) == true else { return }
        proxy.scrollTo(ChatScrollAnchor.bottom, anchor: .bottom)
    }
}

enum ChatScrollAnchor: Hashable { case imported(String); static let bottom = "bottom"; static let space = "chatScrollViewport" }

struct ChatVisibleRows: Equatable {
    var rows: [UUID: CGRect] = [:]
    var archiveFocus: CGRect?
    var start: CGFloat?
    var bottom: CGFloat?
    var height: CGFloat = 0
}
private struct ChatFrames: PreferenceKey {
    static let defaultValue = ChatVisibleRows()
    static func reduce(value: inout ChatVisibleRows, nextValue: () -> ChatVisibleRows) {
        let next = nextValue()
        value.rows.merge(next.rows) { _, new in new }
        if let focus = next.archiveFocus { value.archiveFocus = focus }
        if let start = next.start { value.start = start }
        if let bottom = next.bottom { value.bottom = bottom }
        value.height = max(value.height, next.height)
    }
}

extension View {
    func trackArchiveFocus(_ isFocused: Bool) -> some View {
        background {
            if isFocused {
                GeometryReader { geo in
                    Color.clear.preference(key: ChatFrames.self, value: ChatVisibleRows(archiveFocus: geo.frame(in: .named(ChatScrollAnchor.space))))
                }
            }
        }
    }

    func chatRow(_ id: UUID) -> some View {
        background { GeometryReader { geo in
            Color.clear.preference(key: ChatFrames.self, value: ChatVisibleRows(rows: [id: geo.frame(in: .named(ChatScrollAnchor.space))]))
        } }
    }

    func trackChatViewport(_ viewport: ChatViewport) -> some View {
        coordinateSpace(name: ChatScrollAnchor.space)
            .background { GeometryReader { geo in
                Color.clear.preference(key: ChatFrames.self, value: ChatVisibleRows(height: geo.size.height))
            } }
            .onPreferenceChange(ChatFrames.self) { viewport.measured($0) }
    }
}

struct ChatTopMarker: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ChatFrames.self, value: ChatVisibleRows(start: geo.frame(in: .named(ChatScrollAnchor.space)).minY))
        }.frame(height: 20)
    }
}

struct ChatBottomMarker: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: ChatFrames.self, value: ChatVisibleRows(bottom: geo.frame(in: .named(ChatScrollAnchor.space)).maxY))
        }.frame(height: 1).id(ChatScrollAnchor.bottom)
    }
}

struct HistoryPageButton: View {
    let earlier: Bool
    let action: () -> Void
    var body: some View {
        Button(earlier ? "Earlier messages" : "Later messages", systemImage: earlier ? "chevron.up" : "chevron.down", action: action)
            .controlSize(.small).padding(.vertical, 8)
    }
}

struct JumpToLatestButton: View {
    @ObservedObject var scroll: ChatScrollModel
    let conversationID: UUID
    let action: () -> Void
    var body: some View {
        if let label = scroll.jumpLabel(conversationID) {
            Button(action: action) {
                Label(label, systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassSurface(in: Capsule(), interactive: true, fallback: .regularMaterial).plainSurfaceShadow()
            }
            .buttonStyle(.plain).padding(.bottom, 12)
            .accessibilityLabel("Jump to latest message")
            .help("Jump to latest message")
        }
    }
}
