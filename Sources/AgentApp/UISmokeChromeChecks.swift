import Foundation

/// C1-C12 of briefs/P14.md item 4, read from the `chrome` facts only; each failure is one line for `errors` (0.5 pt tolerance).
enum ChromeChecks {
    static let tolerance = 0.5
    static let rowButtons = ["hide_sidebar", "import_template", "new_bot"]
    static let topEdges = ["sidebar_row", "chat_header", "details_header"]

    static func run(_ facts: [String: Any]) -> (passed: [String: Bool], errors: [String]) {
        let all: [(String, ([String: Any]) -> [String])] = [("C1", c1), ("C2", c2), ("C3", c3), ("C4", c4), ("C5", c5), ("C6", c6),
                                                            ("C7", c7), ("C8", c8), ("C9", c9), ("C10", c10), ("C11", c11), ("C12", c12)]
        var passed: [String: Bool] = [:], errors: [String] = []
        for (name, check) in all {
            let failures = check(facts)
            passed[name] = failures.isEmpty
            errors += failures.map { "chrome \(name): \($0)" }
        }
        return (passed, errors)
    }

    static func c1(_ facts: [String: Any]) -> [String] {
        let window = object(facts, "window")
        var errors: [String] = []
        if window["title_visibility"] as? String != "hidden" { errors.append("title is not hidden") }
        if window["title"] as? String != AppConstants.name { errors.append("title is \(window["title"] ?? "missing"), not \(AppConstants.name)") }
        return errors
    }

    static func c2(_ facts: [String: Any]) -> [String] {
        let window = object(facts, "window"), mask = window["style_mask"] as? [String] ?? []
        return ["titled", "fullSizeContentView"].filter { !mask.contains($0) }.map { "style mask lacks \($0)" }
            + (window["titlebar_transparent"] as? Bool == true ? [] : ["titlebar is not transparent"])
    }

    static func c3(_ facts: [String: Any]) -> [String] {
        let lights = object(facts, "traffic_lights")
        var errors: [String] = []
        if lights["count"] as? Int != 3 { errors.append("\(lights["count"] ?? 0) traffic lights, not 3") }
        if lights["any_hidden"] as? Bool != false { errors.append("a traffic light is hidden") }
        return errors
    }

    /// The bar is gone as geometry: the sidebar row and both headers start at the window's top edge.
    static func c4(_ facts: [String: Any]) -> [String] {
        let layout = object(facts, "layout")
        return topEdges.compactMap { id in
            guard let rect = ChromeGeometry.rect(layout[id]) else { return "\(id) not on screen" }
            return abs(rect.minY) <= tolerance ? nil : "\(id) starts at y=\(rect.minY), not 0"
        }
    }

    static func c5(_ facts: [String: Any]) -> [String] {
        let layout = object(facts, "layout")
        guard let row = ChromeGeometry.rect(layout["sidebar_row"]), let list = ChromeGeometry.rect(layout["sidebar_list"]) else { return ["sidebar row or list not on screen"] }
        let reserved = ChromeGeometry.number(object(facts, "bar")["reserved_top"]) ?? 0
        var errors: [String] = []
        if row.height + tolerance < reserved { errors.append("row is \(row.height) pt, reserved_top is \(reserved)") }
        if list.minY + tolerance < row.maxY { errors.append("list starts at \(list.minY), above the row's bottom \(row.maxY)") }
        return errors
    }

    /// No row button within 4 pt of a light, and the leftmost button at least 8 pt right of the lights.
    static func c6(_ facts: [String: Any]) -> [String] {
        let buttons = rowButtons.compactMap { id in ChromeGeometry.rect(object(facts, "layout")[id]).map { (id, $0) } }
        guard buttons.count == rowButtons.count else { return ["row buttons not all on screen"] }
        let lights = object(facts, "traffic_lights")
        let frames = (lights["frames"] as? [String: Any] ?? [:]).compactMap { ChromeGeometry.rect($0.value) }
        var errors: [String] = []
        for (id, rect) in buttons where frames.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(rect) }) { errors.append("\(id) within 4 pt of a light") }
        if let maxX = ChromeGeometry.number(lights["max_x"]), let left = buttons.map({ Double($0.1.minX) }).min(), maxX + 8 > left + tolerance {
            errors.append("leftmost button at x=\(left), lights end at \(maxX)")
        }
        return errors
    }

    static func c7(_ facts: [String: Any]) -> [String] {
        let items = (object(facts, "bar")["toolbar"] as? [String: Any])?["item_frames"] as? [[String: Any]] ?? []
        return rowButtons.flatMap { id -> [String] in
            guard let rect = ChromeGeometry.rect(object(facts, "layout")[id]) else { return [] }
            return items.filter { ChromeGeometry.rect($0["frame"])?.intersects(rect) == true }.map { "\(id) meets toolbar item \($0["class"] ?? "?")" }
        }
    }

    /// Buttons hit app content (never chrome, never the drag strip); blank points hit the drag strip or the system title zone.
    static func c8(_ facts: [String: Any]) -> [String] {
        let hit = object(facts, "hit")
        var errors = rowButtons.compactMap { id -> String? in
            guard let fact = hit[id] as? [String: Any] else { return "\(id) not probed" }
            return fact["kind"] as? String == "app_content" ? nil : "\(id) hits \(fact["kind"] ?? "?") (\(fact["class"] ?? "?"))"
        }
        for id in ["sidebar_row_blank", "chat_header_blank"] {
            guard let fact = hit[id] as? [String: Any] else { errors.append("\(id) not probed"); continue }
            if !["drag_area", "system_title_zone"].contains(fact["kind"] as? String ?? "") { errors.append("\(id) hits \(fact["kind"] ?? "?") (\(fact["class"] ?? "?"))") }
        }
        return errors
    }

    static func c9(_ facts: [String: Any]) -> [String] {
        let window = object(facts, "window")
        return (window["is_movable"] as? Bool == true ? [] : ["window is not movable"])
            + (window["movable_by_background"] as? Bool == false ? [] : ["window is movable by background"])
    }

    static func c10(_ facts: [String: Any]) -> [String] {
        let menu = object(facts, "menu")
        let toggles = menu["enabled_sidebar_toggles"] as? Int ?? 0
        return (toggles == 1 ? [] : ["\(toggles) enabled sidebar toggles in the menu, not 1"])
            + ((menu["full_screen_items"] as? [String] ?? []).isEmpty && (menu["full_screen_action"] as? [String: Any])?["enabled"] as? Bool != true
               ? ["no full-screen menu item or enabled full-screen command"] : [])
    }

    static func c11(_ facts: [String: Any]) -> [String] {
        let hidden = object(facts, "hidden_sidebar")
        guard !hidden.isEmpty else { return ["hidden sidebar not probed"] }
        var errors: [String] = []
        if let show = ChromeGeometry.rect(hidden["show_sidebar"]), let maxX = ChromeGeometry.number(hidden["lights_max_x"]) {
            if maxX + 8 > Double(show.minX) + tolerance { errors.append("show-sidebar button at x=\(show.minX), lights end at \(maxX)") }
        } else { errors.append("show-sidebar button did not appear") }
        if hidden["restored"] as? Bool != true { errors.append("sidebar state not restored") }
        return errors
    }

    static func c12(_ facts: [String: Any]) -> [String] {
        let lookup = object(facts, "window")["main_window_lookup"] as? String
        return lookup == "title" ? [] : ["main window found by \(lookup ?? "nothing"), not by title"]
    }

    private static func object(_ facts: [String: Any], _ key: String) -> [String: Any] { facts[key] as? [String: Any] ?? [:] }
}
