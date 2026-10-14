import Foundation

/// Where every right-panel control lives after P21b: on top, or folded under that section's "Advanced". Like
/// `SettingsLayout`, the tests assert that nothing the panel had before was lost or listed twice.
enum InspectorLayout {
    enum Section: String, CaseIterable { case model, routineEditor, group }
    enum Home: Equatable { case simple, advanced }

    /// Every control these three places had before P21b (0.4.5), by stable id.
    static let baseline = [
        "model.current", "model.source", "model.picker", "model.refresh", "model.caption", "model.notes", "model.error", "model.footer",
        "model.roles", "model.ranOn", "model.useBoxDefault", "model.switchChat", "model.subAgents",
        "routine.name", "routine.schedule", "routine.time", "routine.weekday", "routine.rawCron", "routine.summary", "routine.prompt", "routine.save",
        "group.name", "group.count", "group.owner", "group.members", "group.memberWhere", "group.remove", "group.add", "group.routing"
    ]
    /// New in P21b: the plain status line, Every N hours, the mute switch (before only in the sidebar's menu) and the routing detail split out.
    static let added = ["model.status", "routine.everyHours", "group.mute", "group.mentions", "group.contextCap"]

    static let entries: [(id: String, section: Section, home: Home)] = [
        ("model.current", .model, .simple), ("model.picker", .model, .simple), ("model.refresh", .model, .simple), ("model.status", .model, .simple),
        ("model.source", .model, .advanced), ("model.caption", .model, .advanced), ("model.notes", .model, .advanced), ("model.error", .model, .advanced),
        ("model.footer", .model, .advanced), ("model.roles", .model, .advanced), ("model.ranOn", .model, .advanced),
        ("model.useBoxDefault", .model, .advanced), ("model.switchChat", .model, .advanced), ("model.subAgents", .model, .advanced),
        ("routine.name", .routineEditor, .simple), ("routine.schedule", .routineEditor, .simple), ("routine.time", .routineEditor, .simple),
        ("routine.weekday", .routineEditor, .simple), ("routine.everyHours", .routineEditor, .simple), ("routine.summary", .routineEditor, .simple),
        ("routine.prompt", .routineEditor, .simple), ("routine.save", .routineEditor, .simple), ("routine.rawCron", .routineEditor, .advanced),
        ("group.name", .group, .simple), ("group.count", .group, .simple), ("group.owner", .group, .simple), ("group.members", .group, .simple),
        ("group.remove", .group, .simple), ("group.add", .group, .simple), ("group.mute", .group, .simple),
        ("group.memberWhere", .group, .advanced), ("group.routing", .group, .advanced), ("group.mentions", .group, .advanced),
        ("group.contextCap", .group, .advanced)
    ]

    static func home(of id: String) -> Home? { entries.first { $0.id == id }?.home }
    static func ids(_ section: Section, _ home: Home) -> [String] { entries.filter { $0.section == section && $0.home == home }.map(\.id) }
}
