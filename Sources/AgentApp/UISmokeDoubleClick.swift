import AppKit
import Foundation

/// `--ui-smoke`'s `top_bar_double_click` (briefs/P24.md item 5): a synthetic double-click on blank top-row space of each pane
/// (high up, inside the hidden title bar's zone, where it used to do nothing) must zoom the window; the frame is restored after each.
@MainActor enum UISmokeDoubleClick {
    /// Blank points in top-left window coordinates, 10 pt below the top edge: the sidebar row between the lights and its
    /// buttons, the chat header's trailing end and the Details header's middle.
    static func points(frames: [String: CGRect], lightsMaxX: Double?) -> [String: CGPoint] {
        var points: [String: CGPoint] = [:]
        if let row = frames["sidebar_row"] {
            let left = ChromeHit.buttons.compactMap { frames[$0]?.minX }.filter { row.contains(CGPoint(x: $0, y: row.midY)) }.min() ?? row.maxX
            points["sidebar_row"] = CGPoint(x: (max(row.minX, CGFloat(lightsMaxX ?? 0)) + left) / 2, y: row.minY + 10)
        }
        if let header = frames["chat_header"] { points["chat_header"] = CGPoint(x: header.maxX - 40, y: header.minY + 10) }
        if let header = frames["details_header"] { points["details_header"] = CGPoint(x: header.midX, y: header.minY + 10) }
        return points
    }

    static func collect(window: NSWindow?, budget: Duration, errors: inout [String]) async -> [String: Any] {
        let setting = WindowDragDecision.doubleClickSetting()
        let action = WindowDragDecision.doubleClick(setting)
        var report: [String: Any] = ["setting": setting ?? NSNull(), "action": "\(action)"]
        guard let window, window.isVisible, !window.styleMask.contains(.fullScreen) else { report["skipped"] = "main window not visible or in full screen"; return report }
        guard action == .zoom else { report["skipped"] = "macOS is set to \(setting ?? "nil"), not zoom; not clicked"; return report }
        let lights = ChromeFacts.trafficLights(window)
        var results: [String: Any] = [:]
        for (pane, point) in points(frames: ChromeProbes.frames(in: window), lightsMaxX: ChromeGeometry.number(lights["max_x"])).sorted(by: { $0.key < $1.key }) {
            var fact = ChromeHit.probe(window, at: point)
            guard fact["is_drag_area"] as? Bool == true else {
                fact["zoomed"] = false; results[pane] = fact
                errors.append("top bar double-click: \(pane) point \(point) is not blank drag space (\(fact["class"] ?? "none"))"); continue
            }
            let before = window.frame
            doubleClick(window, at: point)
            let changed = await HeadlessE2E.wait(budget, poll: .milliseconds(50)) { window.frame != before }
            await UISmokeChrome.settle(budget) { NSDictionary(dictionary: ChromeGeometry.dict(window.frame)) }
            fact["frame_before"] = ChromeGeometry.dict(before); fact["frame_after"] = ChromeGeometry.dict(window.frame)
            fact["zoomed"] = changed
            window.setFrame(before, display: true, animate: false)
            fact["restored"] = await HeadlessE2E.wait(budget, poll: .milliseconds(50)) { window.frame == before }
            if !changed { errors.append("top bar double-click: \(pane) did not zoom the window") }
            if fact["restored"] as? Bool != true { errors.append("top bar double-click: \(pane) frame not restored") }
            results[pane] = fact
        }
        if results.isEmpty { errors.append("top bar double-click: no pane header to click") }
        report["panes"] = results
        return report
    }

    /// Mouse down (click count 2) and up at `point`, delivered through the window like a real click.
    static func doubleClick(_ window: NSWindow, at point: CGPoint) {
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            window.sendEvent(event)
        }
    }
}
