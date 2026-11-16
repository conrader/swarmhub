import Foundation

/// Every visible string of the group panel's simple part. Same rules as `SimpleCopy`: plain words, "agents", never
/// "bots". The detail behind "Advanced" keeps its own words in `GroupRoutingDetails`.
enum InspectorCopy {
    static let advanced = "Advanced"

    // Groups
    static let members = "Members"
    static let groupName = "Group name"
    static let rename = "Rename"
    static func inThisChat(_ count: Int) -> String { "\(count) in this chat" }
    static let owner = "Owner"
    static let remove = "Remove"
    static func removeHelp(_ name: String) -> String { "Remove \(name) from the group" }
    static let addAgent = "Add agent"
    static let mute = "Mute notifications"
    static let close = "Close"

    /// Static strings plus the functions with sample arguments; checked by the tests.
    static var all: [String] { [advanced, members, groupName, rename, inThisChat(3), owner, remove, removeHelp("Ada"), addAgent, mute, close] }
}
