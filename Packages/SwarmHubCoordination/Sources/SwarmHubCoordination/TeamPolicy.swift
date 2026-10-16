import Foundation

/// Stable connection and backend identity; display names carry no authority.
public struct TeamIdentity: Codable, Equatable, Sendable {
    public var botID: UUID
    public var connection: String
    public var profile: String
    public init(botID: UUID, connection: String, profile: String) {
        self.botID = botID; self.connection = connection; self.profile = profile
    }
}

/// Permission to route work within a particular user request. This grants no app or backend action permission.
public struct TeamPolicy: Codable, Equatable, Sendable {
    public var version = 1
    public var originID: UUID
    public var decision: String
    public var members: [TeamIdentity]
    public var actions: Set<String> = ["requestHelp", "requestReview", "reportResult", "assign"]
    public var expiresAt: Date?
    public var revokedAt: Date?
    public var ownerDeviceID: String
    public init(originID: UUID, decision: String, members: [TeamIdentity], ownerDeviceID: String) {
        self.originID = originID; self.decision = decision; self.members = members; self.ownerDeviceID = ownerDeviceID
    }
    public func allows(_ action: String, identity: TeamIdentity, at date: Date) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > date } ?? true) && actions.contains(action) && members.contains(identity)
    }
}

public struct TeamLimits: Codable, Equatable, Sendable {
    public var tasks = 12
    public var reviewRounds = 2
    public var handoffDepth = 3
    public var operations = 48
    public var parallelTasks = 1
    public var activeSeconds: TimeInterval = 1800
    public init() {}
    public var isValid: Bool {
        (2...100).contains(tasks) && (1...5).contains(reviewRounds) && (1...10).contains(handoffDepth)
            && (4...400).contains(operations) && (1...4).contains(parallelTasks) && (60...86400).contains(activeSeconds)
    }
}

public struct TeamReporting: Codable, Equatable, Sendable {
    public var quietStartMinute: Int?
    public var quietEndMinute: Int?
    /// nil follows the current device timezone, including daylight saving transitions.
    public var timeZoneID: String?
    public var notifyResults = true
    public var notifyBlockers = true
    public init() {}
    public func isQuiet(at date: Date, deviceTimeZone: TimeZone = .current) -> Bool {
        guard let start = quietStartMinute, let end = quietEndMinute, start != end,
              (0..<1440).contains(start), (0..<1440).contains(end) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZoneID.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return start < end ? minute >= start && minute < end : minute >= start || minute < end
    }
}
