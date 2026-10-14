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
    nonisolated static let chromeWords = ["Titlebar", "Toolbar", "Glass"]

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

    /// Which of `UISmoke.mainWindow()`'s two lookups finds this window: by title `AppConstants.name`, or the any-main fallback.
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
    static func menu(_ main: NSMenu?, window: NSWindow? = nil) -> [String: Any] {
        var toggles: [[String: Any]] = [], fullScreen: [String] = []
        func scan(_ menu: NSMenu) {
            menu.update()
            for item in menu.items {
                if let submenu = item.submenu { scan(submenu); continue }
                let action = item.action.map(NSStringFromSelector) ?? ""
                if action == "toggleSidebar:" || item.title.localizedCaseInsensitiveContains("sidebar") {
                    toggles.append(["title": item.title, "enabled": item.isEnabled, "hidden": item.isHidden, "action": action,
                                    "key": shortcut(item)])
                }
                if action == "toggleFullScreen:" || item.title.localizedCaseInsensitiveContains("full screen") { fullScreen.append(item.title) }
            }
        }
        if let main { scan(main) }
        let titles = { (name: String) in main?.items.first { $0.title == name }?.submenu?.items.map(\.title) ?? [] }
        let tree = (main?.items ?? []).map { item in "\(item.title): " + (item.submenu?.items.map(\.title).joined(separator: " | ") ?? "") }
        return ["sidebar_toggles": toggles, "enabled_sidebar_toggles": toggles.filter { $0["enabled"] as? Bool == true && $0["hidden"] as? Bool != true }.count,
                "full_screen_items": fullScreen, "view_menu": titles("View"), "window_menu": titles("Window"), "tree": tree, "full_screen_action": fullScreenAction(window: window)]
    }

    /// AppKit adds "Enter Full Screen" to the View menu only when that menu opens, so a scan cannot see it; this asks the
    /// responder chain whether the command it would send has a target that accepts it.
    /// Asked of the key window's chain, else of the main window itself (the smoke's app is not always key).
    static func fullScreenAction(window: NSWindow?) -> [String: Any] {
        let action = #selector(NSWindow.toggleFullScreen(_:))
        let item = NSMenuItem(title: "Enter Full Screen", action: action, keyEquivalent: "f")
        let chain = NSApp?.target(forAction: action, to: nil, from: item) as AnyObject?
        guard let target = chain ?? window else { return ["target": NSNull(), "enabled": false] }
        let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? target.responds(to: action)
        return ["target": NSStringFromClass(type(of: target)), "via": chain == nil ? "main_window" : "responder_chain", "enabled": enabled,
                "window_allows": window.map { !$0.collectionBehavior.contains(.fullScreenNone) } ?? false]
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

/// Where the probed views sit (`ChromeProbe`); only views showing in the window count.
@MainActor enum ChromeProbes {
    private final class Box { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    private static var views: [String: Box] = [:]

    static func register(_ view: NSView, id: String) { views[id] = Box(view) }

    static func frames(in window: NSWindow) -> [String: CGRect] {
        views.compactMapValues { box in
            guard let view = box.view, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  let rect = ChromeGeometry.frame(of: view), rect.width > 0, rect.height > 0,
                  rect.intersects(CGRect(origin: .zero, size: window.frame.size)) else { return nil }
            return rect
        }
    }
}

/// What a click at a point would land on: app content, our drag strip, the system's title zone, or other chrome.
enum ChromeHit {
    static let buttons = ["hide_sidebar", "search", "new_bot", "show_sidebar"]

    /// `chain` is the hit view's class name, then its ancestors' up to the theme frame.
    static func classify(chain: [String], inContent: Bool, yFromTop: Double, systemZone: Double) -> [String: Any] {
        let isDrag = chain.contains { $0.contains("WindowDragView") }
        let chrome = !inContent && chain.contains { name in ChromeFacts.chromeWords.contains { name.contains($0) } }
        let kind = chain.isEmpty ? "none" : isDrag ? "drag_area" : inContent ? "app_content"
            : chrome && yFromTop < systemZone ? "system_title_zone" : chrome ? "chrome" : "other"
        return ["class": chain.first ?? "none", "chain": Array(chain.prefix(6)), "kind": kind, "blocked_by_chrome": chrome, "is_drag_area": isDrag]
    }

    @MainActor static func probe(_ window: NSWindow, at point: CGPoint) -> [String: Any] {
        let height = window.frame.height
        var chain: [String] = [], inContent = false
        if let frame = window.contentView?.superview, let hit = frame.hitTest(NSPoint(x: point.x, y: height - point.y)) {
            var view: NSView? = hit
            while let current = view, current !== frame { chain.append(NSStringFromClass(type(of: current))); view = current.superview }
            if let content = window.contentView { inContent = hit === content || hit.isDescendant(of: content) }
        }
        var fact = classify(chain: chain, inContent: inContent, yFromTop: Double(point.y), systemZone: Double(height - window.contentLayoutRect.maxY))
        fact["point"] = ["x": Double(point.x), "y": Double(point.y)]
        return fact
    }

    /// Each button's centre, a blank point of the sidebar row (between the lights and the buttons) and of the chat header.
    @MainActor static func facts(_ window: NSWindow, frames: [String: CGRect], lightsMaxX: Double?) -> [String: Any] {
        var facts: [String: Any] = [:]
        for id in buttons { if let rect = frames[id] { facts[id] = probe(window, at: CGPoint(x: rect.midX, y: rect.midY)) } }
        if let row = frames["sidebar_row"] {
            let left = buttons.compactMap { frames[$0]?.minX }.filter { row.contains(CGPoint(x: $0, y: row.midY)) }.min() ?? row.maxX
            let start = max(row.minX, CGFloat(lightsMaxX ?? 0))
            facts["sidebar_row_blank"] = probe(window, at: CGPoint(x: (start + left) / 2, y: row.midY))
        }
        if let header = frames["chat_header"] { facts["chat_header_blank"] = probe(window, at: CGPoint(x: header.maxX - 40, y: header.midY)) }
        return facts
    }
}

/// `--ui-smoke`'s `chrome` object (briefs/P14.md item 4): what macOS draws above the content and where, then C1-C12.
@MainActor enum UISmokeChrome {
    static func fullScreenRequested(arguments: [String] = CommandLine.arguments) -> Bool { arguments.contains("--ui-smoke-fullscreen") }

    static func collect(window: NSWindow?, store: AppStore? = nil, budget: Duration, menu: NSMenu? = NSApp?.mainMenu,
                        fullScreen: Bool = fullScreenRequested()) async -> [String: Any] {
        guard let window, window.isVisible else { return ["skipped": "main window not visible"] }
        await settle(budget) { layoutSnapshot(window) }
        var report = facts(window, menu: menu)
        if let store {
            report["info_panel"] = await infoPanel(window, store: store, budget: budget)
            report["hidden_sidebar"] = await hiddenSidebar(window, store: store, budget: budget)
        }
        let checks = ChromeChecks.run(report)
        report["checks"] = checks.passed
        report["errors"] = checks.errors
        if fullScreen { report["fullscreen"] = await fullScreenRun(window, budget: budget) }
        return report
    }

    static func facts(_ window: NSWindow, menu: NSMenu?) -> [String: Any] {
        let lights = ChromeFacts.trafficLights(window)
        let frames = ChromeProbes.frames(in: window)
        return [
            "window": ChromeFacts.window(window, windows: NSApp?.windows ?? [window]),
            "bar": ChromeFacts.bar(window),
            "traffic_lights": lights,
            "layout": frames.mapValues(ChromeGeometry.dict),
            "hit": ChromeHit.facts(window, frames: frames, lightsMaxX: ChromeGeometry.number(lights["max_x"])),
            "menu": ChromeFacts.menu(menu, window: window)
        ]
    }

    static func layoutSnapshot(_ window: NSWindow) -> NSDictionary {
        NSDictionary(dictionary: ChromeProbes.frames(in: window).mapValues(ChromeGeometry.dict).merging(["lights": ChromeFacts.trafficLights(window)]) { $1 })
    }

    /// Item 8: whether the right column shows, how wide, by which mechanism; toggled once (open, closed, open) to prove the binding.
    static func infoPanel(_ window: NSWindow, store: AppStore, budget: Duration) async -> [String: Any] {
        func state() -> [String: Any] {
            let header = ChromeProbes.frames(in: window)["details_header"]
            return ["show_info": store.showInfo, "visible": header != nil, "width": header.map { Double($0.width) as Any } ?? NSNull()]
        }
        var steps: [[String: Any]] = [state()]
        for open in [false, true] {
            store.showInfo = open
            _ = await HeadlessE2E.wait(budget, poll: .milliseconds(100)) { (ChromeProbes.frames(in: window)["details_header"] != nil) == open }
            await settle(budget) { layoutSnapshot(window) }
            steps.append(state())
        }
        let first = steps[0]
        return ["presented": first["visible"] as? Bool ?? false, "width": first["width"] ?? NSNull(), "mechanism": RightColumnMechanism.current.rawValue,
                "toggle": steps, "binding_ok": steps.map { $0["visible"] as? Bool ?? false } == [true, false, true]]
    }

    /// Hides the sidebar, waits for the show-sidebar item, records it, then restores the sidebar.
    static func hiddenSidebar(_ window: NSWindow, store: AppStore, budget: Duration) async -> [String: Any] {
        let before = store.sidebarHidden
        store.sidebarHidden = true
        let shown = await HeadlessE2E.wait(budget, poll: .milliseconds(100)) { ChromeProbes.frames(in: window)["show_sidebar"] != nil }
        await settle(budget) { layoutSnapshot(window) }
        let frames = ChromeProbes.frames(in: window)
        let lights = ChromeFacts.trafficLights(window)
        var report: [String: Any] = ["show_button_appeared": shown, "sidebar_row_visible": frames["sidebar_row"] != nil,
                                     "show_sidebar": frames["show_sidebar"].map { ChromeGeometry.dict($0) as Any } ?? NSNull(),
                                     "lights_max_x": lights["max_x"] ?? NSNull(),
                                     "hit": ChromeHit.facts(window, frames: frames, lightsMaxX: ChromeGeometry.number(lights["max_x"]))["show_sidebar"] ?? NSNull()]
        store.sidebarHidden = before
        let back = await HeadlessE2E.wait(budget, poll: .milliseconds(100)) { ChromeProbes.frames(in: window)["sidebar_row"] != nil }
        await settle(budget) { layoutSnapshot(window) }
        report["restored"] = back && store.sidebarHidden == before && ChromeProbes.frames(in: window)["show_sidebar"] == nil
        return report
    }

    /// `--ui-smoke-fullscreen`: the window enters full screen itself, C4 and C8 run again, any system toolbar window is noted, then it leaves.
    static func fullScreenRun(_ window: NSWindow, budget: Duration) async -> [String: Any] {
        var report: [String: Any] = [:]
        window.toggleFullScreen(nil)
        let entered = await HeadlessE2E.wait(.seconds(10), poll: .milliseconds(100)) { window.styleMask.contains(.fullScreen) }
        report["entered"] = entered
        if entered {
            try? await Task.sleep(for: .milliseconds(800))
            await settle(budget) { layoutSnapshot(window) }
            let facts = facts(window, menu: nil)
            report["layout"] = facts["layout"]; report["hit"] = facts["hit"]; report["bar"] = facts["bar"]
            report["C4"] = ChromeChecks.c4(facts).isEmpty
            report["C8"] = ChromeChecks.c8(facts).isEmpty
            report["errors"] = (ChromeChecks.c4(facts) + ChromeChecks.c8(facts)).map { "fullscreen \($0)" }
            report["system_windows"] = (NSApp?.windows ?? []).filter { $0 !== window && $0.isVisible }.map { NSStringFromClass(type(of: $0)) }
            window.toggleFullScreen(nil)
            report["exited"] = await HeadlessE2E.wait(.seconds(10), poll: .milliseconds(100)) { !window.styleMask.contains(.fullScreen) }
        }
        return report
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
