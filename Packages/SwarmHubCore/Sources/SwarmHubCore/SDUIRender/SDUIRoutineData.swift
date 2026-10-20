import Foundation

/// One routine as the routine documents may bind it (`routine.*`, SCHEMAS.md §13). The app fills it from its own
/// model; the binding paths are defined here once for the Mac (P7b) and iOS (P7c).
public struct SDUIRoutineFields: Equatable, Sendable {
    public let id: String
    public let name: String
    public let prompt: String
    public let schedule: String
    /// The schedule in words, as the app's compiled editor describes it.
    public let scheduleText: String
    public let enabled: Bool
    public let state: String
    public let lastStatus: String?

    public init(id: String, name: String, prompt: String, schedule: String, scheduleText: String, enabled: Bool,
                state: String, lastStatus: String?) {
        self.id = id; self.name = name; self.prompt = prompt; self.schedule = schedule; self.scheduleText = scheduleText
        self.enabled = enabled; self.state = state; self.lastStatus = lastStatus
    }

    var values: [String: SDUIDataValue] {
        var values: [String: SDUIDataValue] = [
            "routine.id": .string(id), "routine.name": .string(name), "routine.prompt": .string(prompt),
            "routine.schedule": .string(schedule), "routine.schedule_text": .string(scheduleText),
            "routine.enabled": .bool(enabled), "routine.state": .string(state)
        ]
        if let lastStatus { values["routine.last_status"] = .string(lastStatus) }
        return values
    }
}

/// One routine result card's own fields (`result.*`), as the compiled card shows them.
public struct SDUIRoutineResultFields: Equatable, Sendable {
    public let routineName: String
    public let routineID: String?
    public let status: String
    public let failed: Bool
    public let title: String
    public let ranText: String
    public let finishedAt: String
    public let hasOutput: Bool
    public let summary: String
    public let error: String?
    public let note: String?

    public init(routineName: String, routineID: String?, status: String, failed: Bool, title: String, ranText: String,
                finishedAt: String, hasOutput: Bool, summary: String, error: String?, note: String?) {
        self.routineName = routineName; self.routineID = routineID; self.status = status; self.failed = failed
        self.title = title; self.ranText = ranText; self.finishedAt = finishedAt; self.hasOutput = hasOutput
        self.summary = summary; self.error = error; self.note = note
    }
}

extension SDUIRoutineTarget {
    /// The create (`routine` nil) or edit form's data: the routine and the profile name.
    public static func editorData(profile: String, routine: SDUIRoutineFields?) -> SDUIData {
        var values = routine?.values ?? [:]
        values["profile.name"] = .string(profile)
        return SDUIData(values)
    }

    /// The result card's data: the routine when it is loaded, then the card's own fields over it.
    public static func cardData(_ result: SDUIRoutineResultFields, profile: String?, routine: SDUIRoutineFields?) -> SDUIData {
        var values = routine?.values ?? [:]
        values["routine.name"] = .string(result.routineName)
        if let id = result.routineID { values["routine.id"] = .string(id) }
        values["result.status"] = .string(result.status)
        values["result.failed"] = .bool(result.failed)
        values["result.title"] = .string(result.title)
        values["result.ran_text"] = .string(result.ranText)
        values["result.finished_at"] = .string(result.finishedAt)
        values["result.has_output"] = .bool(result.hasOutput)
        if !result.summary.isEmpty { values["result.summary"] = .string(result.summary) }
        if let error = result.error { values["result.error"] = .string(error) }
        if let note = result.note { values["result.note"] = .string(note) }
        if let profile { values["profile.name"] = .string(profile) }
        return SDUIData(values)
    }
}
