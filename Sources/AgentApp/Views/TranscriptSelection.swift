import AppKit
import SwiftUI

/// Gesture ownership stays with the transcript even if the text view under mouse-down
/// is recycled. Only mounted TextKit views participate in hit testing and painting.
@MainActor final class TranscriptSelection {
    weak var reader: NSView?
    private let views = NSHashTable<TranscriptTextView>.weakObjects()
    private var conversation: UUID?
    private var messages: [UUID] = []
    private var history: [ArchivedMessage] = []
    private var rows: [TranscriptRowID] = []
    private var order: [TranscriptRowID: Int] = [:]
    private var messageBody: (Int) -> String = { _ in "" }
    private(set) var range: TranscriptRange?
    private var endpointText: [TranscriptRowID: String] = [:]
    private var down: CGPoint?, pointer: CGPoint = .zero
    private var dragged = false
    private var activateLink: (() -> Void)?
    private var timer: Timer?
    private weak var horizontalScroll: NSScrollView?
    var tracking: Bool { down != nil }
    var holdsScroll: Bool { tracking || (hasText && reader?.window?.firstResponder === reader) }
    var hasText: Bool { range.map { $0.anchor != $0.head } ?? false }

    func show(_ conversation: UUID, rows: [UUID], body: @escaping (Int) -> String) {
        if self.conversation != conversation {
            clear()
            messages = []
            history = []
            self.conversation = conversation
            indexRows()
        }
        messageBody = body
        guard messages != rows else { return }
        messages = rows
        indexRows()
    }

    /// The expanded, filtered archive forms a prefix. A folded archive stays unloaded.
    func showHistory(_ conversation: UUID, rows: [ArchivedMessage]) {
        guard self.conversation == conversation, history != rows else { return }
        history = rows
        indexRows()
    }

    private func body(_ index: Int) -> String {
        index < history.count ? history[index].text : messageBody(index - history.count)
    }

    private func indexRows() {
        rows = history.map { .history($0.dedupeKey) } + messages.map { .message($0) }
        order = Dictionary(rows.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        if let range, order[range.anchor.row] == nil || order[range.head.row] == nil { clear() }
        else if range != nil { repaint() }
    }

    func attach(_ view: TranscriptTextView) { views.add(view) }
    func detach(_ view: TranscriptTextView) { views.remove(view) }

    func paint(_ view: TranscriptTextView) {
        let extent = NSRange(location: view.offset, length: (view.string as NSString).length)
        let slice = view.row.flatMap { range?.slice(row: $0, extent: extent, order: order) }
        let local = slice.map { NSRange(location: $0.location - view.offset, length: $0.length) }
        view.highlight(local)
    }
    private func repaint() { for view in views.allObjects { paint(view) } }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        down = nil
        horizontalScroll = nil
        activateLink = nil
        dragged = false
    }

    private func rememberEndpoints() {
        guard let range else { endpointText = [:]; return }
        endpointText = endpointText.filter { $0.key == range.anchor.row || $0.key == range.head.row }
        for row in [range.anchor.row, range.head.row] where endpointText[row] == nil {
            if let index = order[row] { endpointText[row] = body(index) }
        }
    }

    /// Called by the rendered message (and on copy for a recycled message).
    func rendered(_ row: TranscriptRowID?, text: String) {
        guard let row, let old = endpointText[row], old != text else { return }
        endpointText[row] = text
        let previous = range
        range?.rebase(row: row, from: old, to: text)
        if previous?.anchor != range?.anchor || previous?.head != range?.head { repaint() }
    }

    func clear() {
        stopTracking()
        endpointText.removeAll()
        if range != nil { range = nil; repaint() }
    }

    func selectAll() {
        stopTracking()
        guard let first = rows.indices.first(where: { !body($0).isEmpty }),
              let last = rows.indices.last(where: { !body($0).isEmpty }) else { clear(); return }
        range = TranscriptRange(anchor: .init(row: rows[first], offset: 0), head: .init(row: rows[last], offset: body(last).utf16.count))
        rememberEndpoints()
        reader?.window?.makeFirstResponder(reader)
        repaint()
    }

    var copiedText: String {
        for row in Array(endpointText.keys) {
            if let index = order[row] { rendered(row, text: body(index)) }
        }
        guard let range, hasText, let a = order[range.anchor.row], let b = order[range.head.row] else { return "" }
        return (min(a, b)...max(a, b)).compactMap { index -> String? in
            let id = rows[index]
            let string = (endpointText[id] ?? body(index)) as NSString
            guard string.length > 0, let slice = range.slice(row: id, extent: NSRange(location: 0, length: string.length), order: order) else { return nil }
            return string.substring(with: slice)
        }.joined(separator: "\n\n")
    }

    private func point(in view: TranscriptTextView, at location: CGPoint) -> TranscriptRange.Point? {
        guard let id = view.row, order[id] != nil else { return nil }
        let local = view.convert(location, from: nil)
        let length = (view.string as NSString).length
        let index: Int
        if local.y < view.bounds.minY { index = 0 }
        else if local.y > view.bounds.maxY { index = length }
        else { index = min(length, view.characterIndexForInsertion(at: local)) }
        return .init(row: id, offset: view.offset + index)
    }

    func begin(_ view: TranscriptTextView, event: NSEvent) {
        let location = event.locationInWindow
        guard let reader, let window = reader.window, view.window === window, let point = point(in: view, at: location) else { return }
        stopTracking()
        window.makeFirstResponder(reader)
        range = .init(anchor: point, head: point)
        rememberEndpoints()
        pointer = location
        down = location
        if let url = view.link(at: location), let open = view.openLink {
            activateLink = { open(url) }
        }
        repaint()
    }

    func drag(to location: CGPoint) {
        guard let down else { return }
        pointer = location
        guard dragged || hypot(location.x - down.x, location.y - down.y) >= 2 else { return }
        dragged = true
        updateHead()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func end(at location: CGPoint) {
        guard tracking else { return }
        drag(to: location)
        let open = dragged ? nil : activateLink
        stopTracking()
        open?()
    }

    /// Runs even while the pointer rests at an edge. Re-hit-test after scrolling and
    /// subsequent lazy layout, including when the wheel moves underneath a held pointer.
    private func tick() {
        guard let scroll = reader?.enclosingScrollView, reader?.window?.isKeyWindow == true else { stopTracking(); return }
        let clip = scroll.contentView
        let p = clip.convert(pointer, from: nil)
        let sign: CGFloat = clip.isFlipped ? 1 : -1
        let top = clip.isFlipped ? p.y - clip.bounds.minY : clip.bounds.maxY - p.y
        let bottom = clip.bounds.height - top
        let edge: CGFloat = 28
        let delta = min(60, max(0, edge - bottom)) - min(60, max(0, edge - top))
        if delta != 0 {
            let next = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: sign * delta))
            clip.scroll(to: next.origin)
            scroll.reflectScrolledClipView(clip)
        }
        if let inner = horizontalScroll, inner !== scroll {
            let clip = inner.contentView
            let p = clip.convert(pointer, from: nil)
            if (clip.bounds.minY...clip.bounds.maxY).contains(p.y) {
                let right = max(0, min(60, edge - (clip.bounds.maxX - p.x)))
                let left = max(0, min(60, edge - (p.x - clip.bounds.minX)))
                if left != right {
                    clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: right - left, dy: 0)).origin)
                    inner.reflectScrolledClipView(clip)
                }
            }
        }
        updateHead()
    }

    private func updateHead() {
        guard let window = reader?.window else { return }
        var nearest: TranscriptTextView?
        var best = (CGFloat.infinity, CGFloat.infinity)
        for view in views.allObjects where view.window === window && !view.isHiddenOrHasHiddenAncestor {
            let visible = view.visibleRect
            guard !visible.isEmpty else { continue }
            let rect = view.convert(visible, to: nil)
            let dy = max(0, max(rect.minY - pointer.y, pointer.y - rect.maxY))
            let dx = max(0, max(rect.minX - pointer.x, pointer.x - rect.maxX))
            if (dy, dx) < best { best = (dy, dx); nearest = view }
        }
        horizontalScroll = nearest?.enclosingScrollView
        guard let nearest, let head = point(in: nearest, at: pointer), head != range?.head else { return }
        let changedRow = range?.head.row != head.row
        range?.head = head
        if changedRow { rememberEndpoints() }
        repaint()
    }
}

private extension TranscriptTextView {
    /// Use the hit glyph itself for links. An insertion index can point one character
    /// past a link when the pointer lands on the trailing half of its final glyph.
    func link(at location: CGPoint) -> URL? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var p = convert(location, from: nil)
        p.x -= textContainerOrigin.x
        p.y -= textContainerOrigin.y
        let glyph = layout.glyphIndex(for: p, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(p) else { return nil }
        return storage.attribute(.link, at: layout.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? URL
    }
}
