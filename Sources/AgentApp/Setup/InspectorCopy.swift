import Foundation

/// Every visible string of the right panel's simple parts (P21b): the model line and picker, the routine editor's
/// schedule picker and the group members. Same rules as `SimpleCopy`: plain words, "agents", never "bots" (P21 D12).
/// The detail behind each "Advanced" keeps its own words in the `…Advanced` views.
enum InspectorCopy {
    static let advanced = "Advanced"

    // Overview model section
    static func modelLine(_ name: String, supplier: String?) -> String { "Model: " + ([name] + [supplier].compactMap { $0 }).joined(separator: " · ") }
    static let modelChecking = "Model: checking…"
    static let modelNotReported = "Model: not reported yet"
    static let changeModel = "Change model…"
    static let switching = "Switching…"
    static let reloadModels = "Reload this agent's models, skills and tools"
    static let modelsLoading = "Loading this agent's models…"
    static let modelsNotListed = "This agent's models can't be listed right now. Details under Advanced."
    static let modelSendFirst = "Send a message first; then you can choose the model for this chat."
    static let modelFixed = "This chat's model can't be changed from here. Details under Advanced."
    static let modelAttention = "Something about this agent's models needs a look. Details under Advanced."

    // Routine editor
    static let newRoutine = "New routine"
    static let editRoutine = "Edit routine"
    static let routineName = "Name"
    static let schedule = "Repeats"
    static let everyDay = "Every day", weekdays = "Weekdays", everyWeek = "Every week", everyFewHours = "Every few hours"
    static let customSchedule = "Custom (see Advanced)"
    static let at = "at", on = "on", every = "every"
    static func hours(_ count: Int) -> String { count == 1 ? "1 hour" : "\(count) hours" }
    static func scheduleSummary(_ description: String) -> String { "\(description) · times use your box's time zone" }
    static let customSummary = "A schedule the picker can't show. It is kept exactly as written under Advanced."
    static let routinePrompt = "What should the agent do?"
    static let create = "Create"
    static let save = "Save"
    static let cancel = "Cancel"

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
    static var all: [String] {
        [advanced, modelLine("model-a", supplier: "Supplier"), modelLine("model-a", supplier: nil), modelChecking, modelNotReported,
         changeModel, switching, reloadModels, modelsLoading, modelsNotListed, modelSendFirst, modelFixed, modelAttention,
         newRoutine, editRoutine, routineName, schedule, everyDay, weekdays, everyWeek, everyFewHours, customSchedule, at, on, every,
         hours(1), hours(6), scheduleSummary("Daily at 09:00"), customSummary, routinePrompt, create, save, cancel,
         members, groupName, rename, inThisChat(3), owner, remove, removeHelp("Ada"), addAgent, mute, close]
    }
}
