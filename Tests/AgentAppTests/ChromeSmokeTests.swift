import AppKit
import Foundation
import Testing
@testable import AgentApp

// MARK: briefs/P14.md item 6 — window chrome facts and checks on synthetic windows and view trees

@MainActor private func chromeWindow(_ mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: mask, backing: .buffered, defer: true)
    window.title = AppConstants.name
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    return window
}

@Test func chromeConvertsBottomLeftRectsToTopLeft() {
    let rect = ChromeGeometry.topLeft(CGRect(x: 10, y: 560, width: 30, height: 28), windowHeight: 600)
    #expect(rect == CGRect(x: 10, y: 12, width: 30, height: 28))
    #expect(ChromeGeometry.rect(ChromeGeometry.dict(rect)) == rect)
    #expect(ChromeGeometry.rect(["x": 1, "y": 2]) == nil)
}

@MainActor @Test func chromeReadsWindowFactsFromASyntheticWindow() {
    let window = chromeWindow()
    let facts = ChromeFacts.window(window, windows: [window])
    #expect(facts["title"] as? String == AppConstants.name)
    #expect(facts["title_visibility"] as? String == "hidden")
    #expect(facts["titlebar_transparent"] as? Bool == true)
    #expect((facts["style_mask"] as? [String])?.contains("fullSizeContentView") == true)
    #expect(facts["movable_by_background"] as? Bool == false)
    #expect(facts["main_window_lookup"] as? String == "none", "an invisible window is found by neither lookup")
    #expect(ChromeFacts.styleMask([.titled]) == ["titled"])
}

@MainActor @Test func chromeReadsBarAndTrafficLights() {
    let window = chromeWindow()
    let bar = ChromeFacts.bar(window)
    #expect((bar["toolbar"] as? [String: Any])?["present"] as? Bool == false)
    #expect(ChromeGeometry.number(bar["reserved_top"]) != nil)
    let lights = ChromeFacts.trafficLights(window)
    #expect(lights["count"] as? Int == 3)
    #expect(lights["any_hidden"] as? Bool == false)
    let min = ChromeGeometry.number(lights["min_x"]) ?? -1, max = ChromeGeometry.number(lights["max_x"]) ?? -1
    #expect(min >= 0 && max > min)
    let plain = chromeWindow([.borderless])
    #expect(ChromeFacts.trafficLights(plain)["any_hidden"] as? Bool == true)
}

@MainActor @Test func chromeReadsSidebarAndFullScreenMenuItems() {
    let main = NSMenu(), viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: ""), view = NSMenu(title: "View")
    viewItem.submenu = view; main.addItem(viewItem)
    let toggle = NSMenuItem(title: "Hide Sidebar", action: Selector(("toggleSidebar:")), keyEquivalent: "s")
    toggle.keyEquivalentModifierMask = [.control, .command]; toggle.isEnabled = true
    view.autoenablesItems = false
    view.addItem(toggle); view.addItem(NSMenuItem(title: "Enter Full Screen", action: Selector(("toggleFullScreen:")), keyEquivalent: "f"))
    let facts = ChromeFacts.menu(main)
    #expect(facts["enabled_sidebar_toggles"] as? Int == 1)
    #expect((facts["sidebar_toggles"] as? [[String: Any]])?.first?["key"] as? String == "⌃⌘S")
    #expect(facts["full_screen_items"] as? [String] == ["Enter Full Screen"])
    let hidden = NSMenuItem(title: "Toggle Sidebar", action: Selector(("toggleSidebar:")), keyEquivalent: ""); hidden.isHidden = true; hidden.isEnabled = true
    view.addItem(hidden)
    #expect(ChromeFacts.menu(main)["enabled_sidebar_toggles"] as? Int == 1, "a hidden item is not a toggle anyone can use")
}

@MainActor @Test func chromeSkipsAnInvisibleWindow() async {
    let report = await UISmokeChrome.collect(window: chromeWindow(), budget: .milliseconds(50), menu: nil)
    #expect(report["skipped"] as? String == "main window not visible")
    #expect(await UISmokeChrome.collect(window: nil, budget: .milliseconds(50), menu: nil)["skipped"] != nil)
}

// MARK: checks

/// A gate-green fact set (the shape `UISmokeChrome.facts` writes); each test below breaks one fact.
private func greenFacts() -> [String: Any] {
    func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [String: Double] { ["x": x, "y": y, "width": w, "height": h] }
    let content: [String: Any] = ["kind": "app_content", "class": "NSHostingView"]
    return [
        "window": ["title": AppConstants.name, "title_visibility": "hidden", "titlebar_transparent": true, "style_mask": ["titled", "fullSizeContentView"],
                   "is_movable": true, "movable_by_background": false, "main_window_lookup": "title"],
        "bar": ["reserved_top": 28.0, "toolbar": ["present": false, "item_frames": [[String: Any]]()]],
        "traffic_lights": ["count": 3, "any_hidden": false, "min_x": 7.0, "max_x": 61.0,
                           "frames": ["close": r(7, 7, 14, 16), "minimize": r(27, 7, 14, 16), "zoom": r(47, 7, 14, 16)]],
        "layout": ["sidebar_row": r(0, 0, 196, 28), "sidebar_list": r(0, 28, 196, 600), "chat_header": r(196, 0, 600, 54),
                   "details_header": r(796, 0, 330, 54), "hide_sidebar": r(90, 2, 24, 24), "search": r(118, 2, 24, 24), "new_bot": r(146, 2, 24, 24)],
        "hit": ["hide_sidebar": content, "search": content, "new_bot": content,
                "sidebar_row_blank": ["kind": "drag_area"], "chat_header_blank": ["kind": "system_title_zone"]],
        "menu": ["enabled_sidebar_toggles": 1, "full_screen_items": ["Enter Full Screen"]],
        "hidden_sidebar": ["show_sidebar": r(81, 15, 24, 24), "lights_max_x": 61.0, "restored": true]
    ]
}

private func with(_ path: [String], _ value: Any, in facts: [String: Any]) -> [String: Any] {
    var facts = facts
    guard let key = path.first else { return facts }
    facts[key] = path.count == 1 ? value : with(Array(path.dropFirst()), value, in: facts[key] as? [String: Any] ?? [:])
    return facts
}

@Test func chromeChecksPassOnGreenFacts() {
    let (passed, errors) = ChromeChecks.run(greenFacts())
    #expect(errors == [])
    #expect(passed.count == 12 && passed.values.allSatisfy { $0 })
}

@Test func chromeChecksTurnRedOneByOne() {
    let base = greenFacts()
    let cases: [(String, [String], Any)] = [
        ("C1", ["window", "title_visibility"], "visible"), ("C1", ["window", "title"], ""),
        ("C2", ["window", "style_mask"], ["titled"]), ("C2", ["window", "titlebar_transparent"], false),
        ("C3", ["traffic_lights", "count"], 2), ("C3", ["traffic_lights", "any_hidden"], true),
        ("C4", ["layout", "chat_header"], ["x": 196.0, "y": 52.0, "width": 600.0, "height": 54.0]),
        ("C5", ["bar", "reserved_top"], 52.0),
        ("C5", ["layout", "sidebar_list"], ["x": 0.0, "y": 10.0, "width": 196.0, "height": 600.0]),
        ("C6", ["layout", "hide_sidebar"], ["x": 63.0, "y": 2.0, "width": 24.0, "height": 24.0]),
        ("C7", ["bar", "toolbar", "item_frames"], [["class": "NSToolbarItemViewer", "frame": ["x": 140.0, "y": 0.0, "width": 42.0, "height": 52.0]]]),
        ("C8", ["hit", "new_bot"], ["kind": "chrome", "class": "NSTitlebarView"]),
        ("C8", ["hit", "search"], ["kind": "drag_area", "class": "AgentApp.WindowDragView"]),
        ("C8", ["hit", "chat_header_blank"], ["kind": "app_content"]),
        ("C9", ["window", "movable_by_background"], true),
        ("C10", ["menu", "enabled_sidebar_toggles"], 2), ("C10", ["menu", "full_screen_items"], [String]()),
        ("C11", ["hidden_sidebar", "restored"], false),
        ("C11", ["hidden_sidebar", "show_sidebar"], ["x": 50.0, "y": 15.0, "width": 24.0, "height": 24.0]),
        ("C12", ["window", "main_window_lookup"], "fallback")
    ]
    for (check, path, value) in cases {
        let (passed, errors) = ChromeChecks.run(with(path, value, in: base))
        #expect(passed.filter { !$0.value }.map(\.key) == [check], "\(path) = \(value)")
        #expect(errors.count >= 1 && errors.allSatisfy { $0.hasPrefix("chrome \(check):") }, "\(errors)")
    }
    #expect(ChromeChecks.c11(with(["hidden_sidebar"], [String: Any](), in: base)) == ["hidden sidebar not probed"])
    let lazyMenu = with(["menu", "full_screen_action"], ["enabled": true], in: with(["menu", "full_screen_items"], [String](), in: base))
    #expect(ChromeChecks.c10(lazyMenu) == [], "AppKit adds the item when the View menu opens; an enabled command counts")
}

// MARK: drag strip

@Test func dragDecisionLeavesFullScreenAndTheSystemZoneAlone() {
    #expect(WindowDragDecision.decide(isFullScreen: true, yFromTop: 40, systemZone: 28, clickCount: 1, doubleClickAction: nil) == .system)
    #expect(WindowDragDecision.decide(isFullScreen: false, yFromTop: 10, systemZone: 28, clickCount: 2, doubleClickAction: nil) == .system)
    #expect(WindowDragDecision.decide(isFullScreen: false, yFromTop: 40, systemZone: 28, clickCount: 1, doubleClickAction: "Minimize") == .drag)
    #expect(WindowDragDecision.decide(isFullScreen: false, yFromTop: 40, systemZone: 28, clickCount: 2, doubleClickAction: "Minimize") == .miniaturize)
    #expect(WindowDragDecision.decide(isFullScreen: false, yFromTop: 40, systemZone: 0, clickCount: 2, doubleClickAction: nil) == .zoom)
}

@Test func doubleClickFollowsTheSystemSetting() {
    #expect(WindowDragDecision.doubleClick(nil) == .zoom)
    #expect(WindowDragDecision.doubleClick("Maximize") == .zoom)
    #expect(WindowDragDecision.doubleClick("Minimize") == .miniaturize)
    #expect(WindowDragDecision.doubleClick("None") == .nothing)
}

// MARK: hit classification

private final class NSTitlebarContainerViewLookalike: NSView {}
private final class _NSGlassEffectLookalike: NSView {}

@Test func hitClassificationNamesPrivateChrome() {
    let drag = ChromeHit.classify(chain: ["AgentApp.WindowDragView", "NSHostingView"], inContent: true, yFromTop: 10, systemZone: 28)
    #expect(drag["kind"] as? String == "drag_area" && drag["is_drag_area"] as? Bool == true)
    let content = ChromeHit.classify(chain: ["_TtC7SwiftUI14_NSHostingView"], inContent: true, yFromTop: 10, systemZone: 28)
    #expect(content["kind"] as? String == "app_content" && content["blocked_by_chrome"] as? Bool == false)
    let zone = ChromeHit.classify(chain: ["NSTitlebarView", "NSTitlebarContainerView"], inContent: false, yFromTop: 10, systemZone: 28)
    #expect(zone["kind"] as? String == "system_title_zone" && zone["blocked_by_chrome"] as? Bool == true)
    let glass = ChromeHit.classify(chain: [NSStringFromClass(_NSGlassEffectLookalike.self)], inContent: false, yFromTop: 40, systemZone: 28)
    #expect(glass["kind"] as? String == "chrome")
    #expect(ChromeHit.classify(chain: [], inContent: false, yFromTop: 0, systemZone: 28)["kind"] as? String == "none")
}

@MainActor @Test func hitProbeWalksAFakeViewTree() {
    let window = chromeWindow()
    let frame = try! #require(window.contentView?.superview)
    let fake = NSTitlebarContainerViewLookalike(frame: NSRect(x: 0, y: 600 - 28, width: 800, height: 28))
    frame.addSubview(fake, positioned: .above, relativeTo: nil)
    let fact = ChromeHit.probe(window, at: CGPoint(x: 400, y: 10))
    #expect((fact["chain"] as? [String])?.first?.contains("TitlebarContainerViewLookalike") == true)
    #expect(fact["blocked_by_chrome"] as? Bool == true)
    #expect(ChromeHit.probe(window, at: CGPoint(x: 400, y: 300))["kind"] as? String == "app_content")
}

@MainActor @Test func sidebarStartsShown() {
    let (store, _, _) = e2eStore()
    #expect(store.sidebarHidden == false)
    #expect(RightColumnMechanism.current.rawValue == "inspector" || RightColumnMechanism.current.rawValue == "transition")
    #expect(UISmokeChrome.fullScreenRequested(arguments: [AppConstants.name, "--ui-smoke", "x"]) == false)
    #expect(UISmokeChrome.fullScreenRequested(arguments: [AppConstants.name, "--ui-smoke", "x", "--ui-smoke-fullscreen"]))
}
