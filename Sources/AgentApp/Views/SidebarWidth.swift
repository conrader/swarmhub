import AppKit
import SwiftUI

/// P23: the sidebar never starts below `SidebarMetrics.width.min`. Older builds autosaved narrower columns (205 pt) under
/// "NSSplitView Subview Frames <window>, SidebarNavigationSplitView" and AppKit restores them past SwiftUI's minimum.
@MainActor enum SidebarWidth {
    static let range = SidebarMetrics.width.min...SidebarMetrics.width.max
    static let autosavePrefix = "NSSplitView Subview Frames ", autosaveSuffix = ", SidebarNavigationSplitView"

    static func clamp(_ width: CGFloat) -> CGFloat { min(max(width, range.lowerBound), range.upperBound) }

    /// The sidebar width in an autosaved frame list ("x, y, width, height, collapsed, hidden" per pane).
    static func savedWidth(_ value: Any?) -> CGFloat? {
        guard let first = (value as? [String])?.first else { return nil }
        let fields = first.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return fields.count > 2 ? Double(fields[2]).map { CGFloat($0) } : nil
    }

    /// Removes workspace sidebar widths outside 240–320, so the column opens at its 280 pt ideal. Settings keeps its own.
    @discardableResult static func dropStaleSavedWidths(in defaults: UserDefaults = .standard) -> [String] {
        let stale = defaults.dictionaryRepresentation().filter { key, value in
            guard key.hasPrefix(autosavePrefix), key.hasSuffix(autosaveSuffix), !key.contains("Settings") else { return false }
            return savedWidth(value).map { !range.contains($0) } ?? true
        }.keys.sorted()
        stale.forEach(defaults.removeObject(forKey:))
        return stale
    }

    /// Pins the split item's limits and moves an out-of-range divider back inside them.
    static func enforce(on splitView: NSSplitView) {
        if let item = (splitView.delegate as? NSSplitViewController)?.splitViewItems.first {
            if item.minimumThickness != range.lowerBound { item.minimumThickness = range.lowerBound }
            if item.maximumThickness != range.upperBound { item.maximumThickness = range.upperBound }
        }
        guard let sidebar = splitView.arrangedSubviews.first, !splitView.isSubviewCollapsed(sidebar) else { return }
        let width = sidebar.frame.width
        if width > 0, !range.contains(width) { splitView.setPosition(clamp(width), ofDividerAt: 0) }
    }

    /// The split view whose first pane holds `view`.
    static func splitView(containing view: NSView) -> NSSplitView? {
        var current: NSView? = view
        while let node = current, let parent = node.superview {
            if let split = parent as? NSSplitView, split.arrangedSubviews.first === node { return split }
            current = parent
        }
        return nil
    }

    /// `--ui-smoke`: the live sidebar width and limits in the workspace window.
    static func live(in window: NSWindow?, errors: inout [String]) -> [String: Any] {
        guard let content = window?.contentView, let split = firstSidebarSplit(in: content), let sidebar = split.arrangedSubviews.first else {
            errors.append("sidebar width: no split view"); return ["found": false]
        }
        let item = (split.delegate as? NSSplitViewController)?.splitViewItems.first
        let width = sidebar.frame.width, collapsed = split.isSubviewCollapsed(sidebar)
        let within = collapsed || range.contains(width)
        if !within { errors.append("sidebar width \(width) outside \(range)") }
        return ["found": true, "width": Double(width), "collapsed": collapsed, "within_range": within,
                "min_thickness": item.map { Double($0.minimumThickness) as Any } ?? NSNull(), "max_thickness": item.map { Double($0.maximumThickness) as Any } ?? NSNull()]
    }

    private static func firstSidebarSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count >= 2 { return split }
        for child in view.subviews { if let found = firstSidebarSplit(in: child) { return found } }
        return nil
    }
}

/// Invisible; once in a window it clamps the enclosing sidebar column (after AppKit's restore has run).
final class SidebarWidthClampView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let split = SidebarWidth.splitView(containing: self) else { return }
            SidebarWidth.enforce(on: split)
        }
    }
}

struct SidebarWidthClamp: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarWidthClampView { SidebarWidthClampView() }
    func updateNSView(_ view: SidebarWidthClampView, context: Context) {}
}
