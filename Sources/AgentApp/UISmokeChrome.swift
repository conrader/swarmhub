import AppKit
import Foundation

/// Window rects in top-left coordinates: x from the window's left edge, y down from its top edge (briefs/P14.md item 4).
enum ChromeGeometry {
    /// AppKit window coordinates (origin bottom-left) → top-left coordinates for a window `height` points tall.
    static func topLeft(_ rect: CGRect, windowHeight height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func dict(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "width": Double(rect.width), "height": Double(rect.height)]
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any], let x = number(value["x"]), let y = number(value["y"]),
              let width = number(value["width"]), let height = number(value["height"]) else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as CGFloat: Double(value)
        case let value as Int: Double(value)
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    /// A view's bounds in top-left window coordinates, or nil when it is not in a window.
    @MainActor static func frame(of view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        return topLeft(view.convert(view.bounds, to: nil), windowHeight: window.frame.height)
    }
}

/// Facts read from the live window and the menu bar; no views of our own needed.
@MainActor enum ChromeFacts {
    static let chromeWords = ["Titlebar", "Toolbar", "Glass"]

    static func window(_ window: NSWindow, windows: [NSWindow]) -> [String: Any] {
        [
            "title": window.title,
            "title_visibility": window.titleVisibility == .hidden ? "hidden" : "visible",
            "titlebar_transparent": window.titlebarAppearsTransparent,
            "style_mask": styleMask(window.styleMask),
            "is_movable": window.isMovable,
            "movable_by_background": window.isMovableByWindowBackground,
            "main_window_lookup": lookup(window, in: windows)
        ]
    }

    static func styleMask(_ mask: NSWindow.StyleMask) -> [String] {
        let names: [(NSWindow.StyleMask, String)] = [(.titled, "titled"), (.closable, "closable"), (.miniaturizable, "miniaturizable"),
                                                     (.resizable, "resizable"), (.fullSizeContentView, "fullSizeContentView"), (.fullScreen, "fullScreen")]
        return names.filter { mask.contains($0.0) }.map(\.1)
    }

    /// Which of `UISmoke.mainWindow()`'s two lookups finds this window: by title "Torvli", or the any-main fallback.
    static func lookup(_ window: NSWindow, in windows: [NSWindow]) -> String {
        if windows.first(where: { $0.isVisible && $0.title == AppConstants.name }) === window { return "title" }
        if windows.first(where: { $0.isVisible && $0.canBecomeMain }) === window { return "fallback" }
        return "none"
    }

    static func bar(_ window: NSWindow) -> [String: Any] {
        let height = window.frame.height
        var toolbar: [String: Any] = ["present": window.toolbar != nil]
        if let bar = window.toolbar {
            toolbar["visible"] = bar.isVisible
            toolbar["item_ids"] = bar.items.map(\.itemIdentifier.rawValue)
        }
        var chromeClasses: Set<String> = [], glass: Set<String> = [], items: [[String: Any]] = []
        if let frame = window.contentView?.superview {
            walk(frame) { view in
                let name = NSStringFromClass(type(of: view))
                if name.contains("Titlebar") || name.contains("Toolbar") { chromeClasses.insert(name) }
                if name.contains("Glass") { glass.insert(name) }
                if name.contains("ToolbarItem"), !view.isHiddenOrHasHiddenAncestor, let rect = ChromeGeometry.frame(of: view) {
                    items.append(["class": name, "frame": ChromeGeometry.dict(rect)])
                }
            }
        }
        toolbar["item_frames"] = items
        return [
            "toolbar": toolbar,
            "reserved_top": Double(height - window.contentLayoutRect.maxY),
            "safe_area_top": Double(window.contentView?.safeAreaInsets.top ?? 0),
            "titlebar_classes": chromeClasses.sorted(),
            "glass_views": glass.sorted()
        ]
    }

    static func trafficLights(_ window: NSWindow) -> [String: Any] {
        let kinds: [(NSWindow.ButtonType, String)] = [(.closeButton, "close"), (.miniaturizeButton, "minimize"), (.zoomButton, "zoom")]
        var frames: [String: Any] = [:], xs: [CGFloat] = [], anyHidden = false, count = 0
        for (kind, name) in kinds {
            guard let button = window.standardWindowButton(kind), let rect = ChromeGeometry.frame(of: button) else { anyHidden = true; continue }
            count += 1
            frames[name] = ChromeGeometry.dict(rect)
            xs += [rect.minX, rect.maxX]
            if button.isHiddenOrHasHiddenAncestor || button.alphaValue == 0 { anyHidden = true }
        }
        return ["frames": frames, "count": count, "min_x": xs.min().map { Double($0) as Any } ?? NSNull(),
                "max_x": xs.max().map { Double($0) as Any } ?? NSNull(), "any_hidden": anyHidden]
    }

    /// Sidebar-toggle and full-screen items in the main menu, validated first so `enabled` is current.
    static func menu(_ main: NSMenu?) -> [String: Any] {
        var toggles: [[String: Any]] = [], fullScreen: [String] = []
        func scan(_ menu: NSMenu) {
            menu.update()
            for item in menu.items {
                if let submenu = item.submenu { scan(submenu); continue }
                let action = item.action.map(NSStringFromSelector) ?? ""
                if action == "toggleSidebar:" || item.title.localizedCaseInsensitiveContains("sidebar") {
                    toggles.append(["title": item.title, "enabled": item.isEnabled, "action": action,
                                    "key": shortcut(item)])
                }
                if action == "toggleFullScreen:" || item.title.localizedCaseInsensitiveContains("full screen") { fullScreen.append(item.title) }
            }
        }
        if let main { scan(main) }
        return ["sidebar_toggles": toggles, "enabled_sidebar_toggles": toggles.filter { $0["enabled"] as? Bool == true }.count,
                "full_screen_items": fullScreen]
    }

    static func shortcut(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        return (mask.contains(.control) ? "⌃" : "") + (mask.contains(.option) ? "⌥" : "") + (mask.contains(.shift) ? "⇧" : "")
            + (mask.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
    }

    static func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for child in view.subviews { walk(child, visit) }
    }
}

/// `--ui-smoke`'s `chrome` object (briefs/P14.md item 4): what macOS draws above the content and where.
@MainActor enum UISmokeChrome {
    static func collect(window: NSWindow?, budget: Duration, menu: NSMenu? = NSApp?.mainMenu) async -> [String: Any] {
        guard let window, window.isVisible else { return ["skipped": "main window not visible"] }
        await settle(budget) { NSDictionary(dictionary: ChromeFacts.trafficLights(window)) }
        return [
            "window": ChromeFacts.window(window, windows: NSApp?.windows ?? [window]),
            "bar": ChromeFacts.bar(window),
            "traffic_lights": ChromeFacts.trafficLights(window),
            "menu": ChromeFacts.menu(menu)
        ]
    }

    /// Waits until `snapshot` reads the same for two 100 ms polls in a row, or `budget` runs out.
    static func settle(_ budget: Duration, snapshot: @escaping @MainActor () -> NSDictionary) async {
        var last = snapshot(), same = 0
        _ = await HeadlessE2E.wait(budget, poll: .milliseconds(100)) {
            let now = snapshot()
            same = now == last ? same + 1 : 0
            last = now
            return same >= 2
        }
    }
}
