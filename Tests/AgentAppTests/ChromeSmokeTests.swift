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
    #expect(facts["title"] as? String == "Torvli")
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
}

@MainActor @Test func chromeSkipsAnInvisibleWindow() async {
    let report = await UISmokeChrome.collect(window: chromeWindow(), budget: .milliseconds(50), menu: nil)
    #expect(report["skipped"] as? String == "main window not visible")
    #expect(await UISmokeChrome.collect(window: nil, budget: .milliseconds(50), menu: nil)["skipped"] != nil)
}
