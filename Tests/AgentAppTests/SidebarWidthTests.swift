import AppKit
import Foundation
import Testing
@testable import AgentApp

// P23: widths saved by older builds (205 pt) must not open the sidebar below 240; drags stay within 240–320.

private func frames(_ width: Double) -> [String] { ["0.000000, 0.000000, \(width), 760.000000, NO, NO", "\(width + 1), 0.000000, 914.000000, 760.000000, NO, NO"] }

@MainActor @Test func clampKeepsTheSidebarWithinItsRange() {
    #expect(SidebarWidth.clamp(205) == 240 && SidebarWidth.clamp(280) == 280 && SidebarWidth.clamp(400) == 320)
    #expect(SidebarWidth.range == 240...320)
}

@MainActor @Test func staleSavedWidthsAreDroppedAndGoodOnesKept() {
    let defaults = isolatedDefaults() // a plain suite name left a SidebarWidthTests-<uuid>.plist in ~/Library/Preferences
    let old = "NSSplitView Subview Frames workspace-AppWindow-1, SidebarNavigationSplitView"
    let good = "NSSplitView Subview Frames workspace-AppWindow-2, SidebarNavigationSplitView"
    let wide = "NSSplitView Subview Frames workspace-AppWindow-3, SidebarNavigationSplitView"
    let settings = "NSSplitView Subview Frames com_apple_SwiftUI_Settings_window, SidebarNavigationSplitView"
    defaults.set(frames(205), forKey: old); defaults.set(frames(280), forKey: good)
    defaults.set(frames(500), forKey: wide); defaults.set(frames(170), forKey: settings)
    #expect(SidebarWidth.savedWidth(frames(205)) == 205)
    #expect(SidebarWidth.dropStaleSavedWidths(in: defaults) == [old, wide])
    #expect(!SidebarWidth.openAtIdeal, "an in-range saved width is kept as the user left it")
    #expect(defaults.object(forKey: old) == nil && defaults.object(forKey: wide) == nil)
    #expect(SidebarWidth.savedWidth(defaults.object(forKey: good)) == 280)
    #expect(SidebarWidth.savedWidth(defaults.object(forKey: settings)) == 170)
    defaults.removeObject(forKey: good)
    #expect(SidebarWidth.dropStaleSavedWidths(in: defaults) == [] && SidebarWidth.openAtIdeal)
    SidebarWidth.openAtIdeal = false
}

@MainActor @Test func enforceMovesANarrowRestoredDividerAndPinsTheLimits() throws {
    let controller = NSSplitViewController()
    let sidebar = NSSplitViewItem(viewController: NSViewController()), detail = NSSplitViewItem(viewController: NSViewController())
    sidebar.viewController.view = NSView(); detail.viewController.view = NSView()
    controller.addSplitViewItem(sidebar); controller.addSplitViewItem(detail)
    controller.view.frame = NSRect(x: 0, y: 0, width: 1120, height: 760)
    controller.splitView.setPosition(205, ofDividerAt: 0)
    controller.view.layoutSubtreeIfNeeded()
    let probe = SidebarWidthClampView()
    sidebar.viewController.view.addSubview(probe)
    #expect(SidebarWidth.splitView(containing: probe) === controller.splitView)
    SidebarWidth.openAtIdeal = false
    SidebarWidth.enforce(on: controller.splitView)
    controller.view.layoutSubtreeIfNeeded()
    #expect(sidebar.minimumThickness == 240 && sidebar.maximumThickness == 320)
    #expect(SidebarWidth.range.contains(controller.splitView.arrangedSubviews[0].frame.width))
    // With nothing valid saved, the first enforce opens the column at its 280 pt ideal, once.
    SidebarWidth.openAtIdeal = true
    SidebarWidth.enforce(on: controller.splitView)
    controller.view.layoutSubtreeIfNeeded()
    #expect(abs(controller.splitView.arrangedSubviews[0].frame.width - 280) < 0.5 && !SidebarWidth.openAtIdeal)
    // Later moves of the divider (a user's drag) stay inside the pinned limits.
    for (target, expected) in [(100.0, 240.0), (600, 320), (300, 300)] {
        controller.splitView.setPosition(target, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        #expect(abs(controller.splitView.arrangedSubviews[0].frame.width - expected) < 0.5, "dragged to \(target): \(controller.splitView.arrangedSubviews[0].frame.width)")
    }
}
