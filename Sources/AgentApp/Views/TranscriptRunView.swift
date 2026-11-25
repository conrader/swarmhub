import AppKit
import SwiftUI

private struct TranscriptRowKey: EnvironmentKey { static let defaultValue: TranscriptRowID? = nil }
private struct TranscriptControllerKey: EnvironmentKey { static let defaultValue: TranscriptSelection? = nil }
extension EnvironmentValues {
    var transcriptRow: TranscriptRowID? {
        get { self[TranscriptRowKey.self] }
        set { self[TranscriptRowKey.self] = newValue }
    }
    var transcriptSelection: TranscriptSelection? {
        get { self[TranscriptControllerKey.self] }
        set { self[TranscriptControllerKey.self] = newValue }
    }
}

struct TranscriptRunView: View {
    @Environment(\.transcriptRow) private var row
    @Environment(\.transcriptSelection) private var selection
    let run: TranscriptText.Run
    var style: TranscriptFont = .body
    var body: some View {
        if let row, let selection {
            NativeRun(run: run, style: style, row: row, selection: selection)
        } else {
            Text(run.value).textSelection(.enabled)
        }
    }
}

enum TranscriptFont: Equatable {
    case body, bold, heading(Int), code, marker, caption

    @MainActor var font: NSFont {
        switch self {
        case .heading(let level):
            let size: CGFloat = switch level { case 1: 22; case 2: 17; default: 13 }
            return .systemFont(ofSize: size, weight: .semibold)
        case .code: return .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        case .marker: return .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        case .caption: return .systemFont(ofSize: NSFont.smallSystemFontSize)
        default: return .systemFont(ofSize: NSFont.systemFontSize, weight: self == .bold ? .bold : .regular)
        }
    }

    @MainActor func render(_ value: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = self == .code ? 0 : 3
        for run in value.runs {
            let intent = run.inlinePresentationIntent ?? []
            var face = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) : font
            if intent.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: face, .paragraphStyle: paragraph,
                .foregroundColor: self == .marker ? NSColor.controlAccentColor : NSColor.labelColor]
            if let link = run.link { attrs[.link] = link }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(value[run.range].characters), attributes: attrs))
        }
        return result
    }
}

private struct NativeRun: NSViewRepresentable {
    let run: TranscriptText.Run
    let style: TranscriptFont
    let row: TranscriptRowID
    let selection: TranscriptSelection

    func makeNSView(context: Context) -> TranscriptTextView {
        let view = TranscriptTextView(usingTextLayoutManager: false)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: TranscriptTextView, context: Context) {
        view.openLink = context.environment.openURL
        view.row = row
        view.offset = run.offset
        if view.value != run.value || view.style != style {
            view.value = run.value
            view.style = style
            view.measuredSizes.removeAll(keepingCapacity: true)
            view.highlight(nil)
            view.textStorage?.setAttributedString(style.render(run.value))
        }
        if view.selection !== selection {
            view.selection?.detach(view)
            view.selection = selection
            selection.attach(view)
        }
        selection.paint(view)
    }

    static func dismantleNSView(_ view: TranscriptTextView, coordinator: ()) { view.selection?.detach(view) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: TranscriptTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let width = max(1, proposal.width ?? CGFloat.greatestFiniteMagnitude)
        if let size = view.measuredSizes[width] { return size }
        let original = container.containerSize
        defer { container.containerSize = original }
        container.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let size = CGSize(width: min(width, ceil(used.width)), height: max(ceil(used.height), ceil(style.font.ascender - style.font.descender)))
        if view.value == run.value && view.style == style {
            if view.measuredSizes.count >= 8 { view.measuredSizes.removeAll(keepingCapacity: true) }
            view.measuredSizes[width] = size
        }
        return size
    }
}

final class TranscriptTextView: NSTextView {
    weak var selection: TranscriptSelection?
    var openLink: OpenURLAction?
    var row: TranscriptRowID?
    var offset = 0
    var style: TranscriptFont?
    var value: AttributedString?

    fileprivate var measuredSizes: [CGFloat: CGSize] = [:]
    private var painted: NSRange?

    /// AppKit's inactive text views can suppress the selection fill. Keep their actual
    /// selected ranges available to accessibility and paint the same range in every run.
    func highlight(_ selection: NSRange?) {
        let next = selection.flatMap { $0.length > 0 ? $0 : nil }
        guard next != painted else { return }
        if let painted { layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: painted) }
        painted = next
        if let next {
            layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, forCharacterRange: next)
        }
        setSelectedRange(next ?? NSRange(location: 0, length: 0))
    }

    override func mouseDown(with event: NSEvent) {
        let modified = !event.modifierFlags.intersection([.command, .shift, .control]).isEmpty
        guard let selection, let window, selection.reader?.window === window, event.clickCount == 1, !modified else {
            super.mouseDown(with: event)
            return
        }
        selection.begin(self, event: event)
    }

    override func selectAll(_ sender: Any?) {
        if let selection, let window, selection.reader?.window === window { selection.selectAll() } else { super.selectAll(sender) }
    }
}
