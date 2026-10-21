import AppKit
import SwiftUI
import Testing
@testable import AgentApp

// The composer row (0.6.0 report: the `+` sat lower than the paperclip, the send button lower than the microphone, and
// the placeholder off centre). The composer is rendered offscreen in dark mode at 2×, and the checks read where each
// control's pixels land: the AppKit-drawn controls (the `+` menu, the round buttons) ignore their SwiftUI label frames,
// so slot frames alone cannot catch the bug. Set SWARMHUB_COMPOSER_SHOTS=<folder> to also write the renders as PNGs.

private let canvas = NSSize(width: 640, height: 300)
private let scale: CGFloat = 2

@MainActor private struct RenderedComposer {
    /// The composer's probes (`composer_attach`, `composer_manage`, `composer_input`, …), top-left points in the canvas.
    let slots: [String: CGRect]
    let bitmap: NSBitmapImageRep
    /// The editor's text view and the height its scroll view shows.
    let textViewHeight: CGFloat?, visibleHeight: CGFloat?

    var controls: [String] { ["composer_attach", "composer_manage", "composer_dictation", "composer_send"] }

    /// The vertical middle (points) of the pixels in `rect` that differ from the composer's background.
    func inkMidY(in rect: CGRect) -> CGFloat? {
        // The composer's own padding, above the row's first slot: never drawn on.
        guard let input = slots["composer_input"], let attach = slots["composer_attach"],
              let background = color(at: CGPoint(x: attach.minX + 2, y: input.minY - 4)) else { return nil }
        var top: Int?, bottom: Int?
        let rows = Int((rect.minY * scale).rounded(.down))..<Int((rect.maxY * scale).rounded(.up))
        let columns = Int((rect.minX * scale).rounded(.down))..<Int((rect.maxX * scale).rounded(.up))
        for y in rows where y >= 0 && y < bitmap.pixelsHigh {
            for x in columns where x >= 0 && x < bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let difference = max(abs(pixel.redComponent - background.redComponent), abs(pixel.greenComponent - background.greenComponent),
                                     abs(pixel.blueComponent - background.blueComponent))
                if difference > 0.08 { top = top ?? y; bottom = y; break }
            }
        }
        guard let top, let bottom else { return nil }
        return CGFloat(top + bottom + 1) / 2 / scale
    }

    func controlInk() -> [String: CGFloat] {
        controls.reduce(into: [:]) { result, id in if let rect = slots[id], let mid = inkMidY(in: rect) { result[id] = mid } }
    }

    private func color(at point: CGPoint) -> NSColor? {
        bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.deviceRGB)
    }
}

@MainActor private func probes(in host: NSView) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    func visit(_ view: NSView) {
        if let probe = view as? ChromeProbeView, probe.probeID.hasPrefix("composer_"), !probe.isHiddenOrHasHiddenAncestor {
            let rect = probe.convert(probe.bounds, to: host)
            frames[probe.probeID] = host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        view.subviews.forEach(visit)
    }
    visit(host)
    return frames
}

@MainActor private func textView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for child in view.subviews { if let found = textView(in: child) { return found } }
    return nil
}

/// The composer as a 1:1 chat with the manager bot shows it: paperclip, `+`, draft, microphone, send.
@MainActor private func renderComposer(_ text: String, shot: String) async throws -> RenderedComposer {
    _ = NSApplication.shared
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let appearance = NSAppearance(named: .darkAqua)
    let root = VStack(spacing: 0) {
        Spacer(minLength: 0)
        ComposerView(text: .constant(text), attachments: .constant([]), isStreaming: false, send: {}, stop: {},
                     manageActions: ManageBotsAction.actions(for: .hermes), dictationContext: "composer-layout")
    }
    .frame(width: canvas.width, height: canvas.height).background(AppColor.chat).environment(\.colorScheme, .dark).environmentObject(store)
    let host = NSHostingView(rootView: root)
    host.appearance = appearance
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = appearance; window.isReleasedWhenClosed = false
    window.contentView = host; host.frame = NSRect(origin: .zero, size: canvas)
    defer { window.contentView = nil; window.close() }
    try await waitUntil { host.layoutSubtreeIfNeeded(); return probes(in: host)["composer_send"] != nil }
    // Let SwiftUI settle (the sizing text, the editor's text view) before drawing.
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = canvas
    (appearance ?? host.effectiveAppearance).performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
    if let folder = ProcessInfo.processInfo.environment["SWARMHUB_COMPOSER_SHOTS"], let png = bitmap.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: folder).appending(path: "composer-\(shot).png"))
    }
    let editor = textView(in: host)
    return RenderedComposer(slots: probes(in: host), bitmap: bitmap, textViewHeight: editor?.frame.height,
                            visibleHeight: editor?.enclosingScrollView?.contentView.bounds.height)
}

/// Every control slot is 28 × 28, shares the draft's bottom edge, and the gaps between neighbours are equal.
@MainActor private func expectRow(_ composer: RenderedComposer) throws {
    let input = try #require(composer.slots["composer_input"])
    let order = ["composer_attach", "composer_manage", "composer_input", "composer_dictation", "composer_send"]
    let frames = try order.map { id in try #require(composer.slots[id], "\(id) is missing: \(composer.slots.keys.sorted())") }
    for id in composer.controls {
        let slot = try #require(composer.slots[id])
        #expect(abs(slot.width - ComposerMetrics.control) < 0.5 && abs(slot.height - ComposerMetrics.control) < 0.5, "\(id) slot is \(slot.size)")
        #expect(abs(slot.maxY - input.maxY) < 0.5, "\(id) bottom \(slot.maxY) vs draft bottom \(input.maxY)")
    }
    let gaps = zip(frames, frames.dropFirst()).map { $1.minX - $0.maxX }
    #expect(gaps.allSatisfy { abs($0 - ComposerMetrics.spacing) < 0.5 }, "gaps \(gaps)")
}

/// Each control's pixels are centred on the last line's 28 pt band, within a point.
@MainActor private func expectControlsCentred(_ composer: RenderedComposer) throws {
    let input = try #require(composer.slots["composer_input"])
    let band = input.maxY - ComposerMetrics.control / 2
    let ink = composer.controlInk()
    #expect(Set(ink.keys) == Set(composer.controls), "controls drawn: \(ink)")
    for (id, mid) in ink.sorted(by: { $0.key < $1.key }) {
        #expect(abs(mid - band) <= 1, "\(id) is drawn centred at \(mid), the row's centre is \(band) (all: \(ink))")
    }
}

/// A text line's ink centre sits slightly below its line box's (caps above, a descender below): within 2 pt of `band`.
private let textTolerance: CGFloat = 2

@Suite(.serialized) @MainActor struct ComposerLayoutTests {
    @Test func emptyComposerCentresEveryControlAndThePlaceholder() async throws {
        let composer = try await renderComposer("", shot: "empty")
        try expectRow(composer)
        try expectControlsCentred(composer)
        let input = try #require(composer.slots["composer_input"])
        #expect(abs(input.height - ComposerMetrics.control) < 0.5, "one line fills one slot: \(input.height)")
        let text = CGRect(x: input.minX, y: input.minY, width: input.width * 0.6, height: input.height)
        let placeholder = try #require(composer.inkMidY(in: text), "the placeholder is drawn")
        #expect(abs(placeholder - input.midY) <= textTolerance, "placeholder centred at \(placeholder), the row at \(input.midY)")
    }

    @Test func typedLineSitsWhereThePlaceholderDid() async throws {
        let empty = try await renderComposer("", shot: "empty-for-typed")
        let typed = try await renderComposer("Message typing", shot: "typed")
        try expectRow(typed)
        try expectControlsCentred(typed)
        let input = try #require(typed.slots["composer_input"])
        #expect(abs(input.height - ComposerMetrics.control) < 0.5, "one typed line keeps one slot: \(input.height)")
        let region = CGRect(x: input.minX, y: input.minY, width: input.width * 0.6, height: input.height)
        let line = try #require(typed.inkMidY(in: region), "the typed text is drawn")
        let placeholder = try #require(empty.inkMidY(in: region))
        #expect(abs(line - input.midY) <= textTolerance, "typed line centred at \(line), the row at \(input.midY)")
        #expect(abs(line - placeholder) <= 1, "typed line at \(line), placeholder at \(placeholder)")
        #expect(typed.textViewHeight.map { $0 <= (typed.visibleHeight ?? 0) + 0.5 } ?? false, "no scrolling: \(String(describing: typed.textViewHeight)) in \(String(describing: typed.visibleHeight))")
    }

    @Test func multilineDraftGrowsAndKeepsControlsOnTheLastLine() async throws {
        let composer = try await renderComposer("Line one\nLine two\nLine three\nLine four", shot: "four-lines")
        try expectRow(composer)
        try expectControlsCentred(composer)
        let input = try #require(composer.slots["composer_input"])
        #expect(input.height > ComposerMetrics.control + 2 * 14 && input.height < ComposerMetrics.maxInput, "four lines: \(input.height)")
        #expect(composer.textViewHeight.map { $0 <= (composer.visibleHeight ?? 0) + 0.5 } ?? false,
                "four lines fit without scrolling: \(String(describing: composer.textViewHeight)) in \(String(describing: composer.visibleHeight))")
        let firstLine = CGRect(x: input.minX, y: input.minY, width: input.width * 0.6, height: ComposerMetrics.control)
        let first = try #require(composer.inkMidY(in: firstLine))
        #expect(abs(first - firstLine.midY) <= textTolerance, "first line centred at \(first), its band at \(firstLine.midY)")
    }

    @Test func longDraftStopsGrowingAndScrolls() async throws {
        let composer = try await renderComposer((1...30).map { "Line \($0)" }.joined(separator: "\n"), shot: "thirty-lines")
        try expectRow(composer)
        try expectControlsCentred(composer)
        let input = try #require(composer.slots["composer_input"])
        #expect(abs(input.height - ComposerMetrics.maxInput) < 0.5, "capped: \(input.height)")
        #expect(composer.textViewHeight.map { $0 > (composer.visibleHeight ?? .infinity) } ?? false, "the editor scrolls the rest")
    }

    @Test func sizingTextKeepsEmptyAndTrailingLines() {
        #expect(ComposerMetrics.sizingText("") == " ")
        #expect(ComposerMetrics.sizingText("One\n") == "One\n ")
        #expect(ComposerMetrics.sizingText("One\nTwo") == "One\nTwo")
    }
}
