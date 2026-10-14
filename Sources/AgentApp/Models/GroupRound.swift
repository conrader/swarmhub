import Foundation

/// P16: a group round in progress, saved with the group so a quit or crash leaves a trace. `userMessageID` is the row
/// that started it, `remaining` the members not asked yet, `active` the member answering now.
struct GroupRound: Codable, Equatable {
    var userMessageID: UUID; var remaining: [UUID]; var active: UUID?
}
