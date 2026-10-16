import Foundation

/// P49: quiet hours as minutes after midnight in the Mac's time zone; an end before the start runs over midnight.
struct QuietHours: Equatable, Sendable {
    static let defaultStart = 22 * 60, defaultEnd = 8 * 60
    var start = defaultStart, end = defaultEnd

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60 % 24, minute % 60) }
    /// "22:00–08:00".
    var label: String { "\(Self.clock(start))–\(Self.clock(end))" }
    /// "Warsaw" for Europe/Warsaw, "New York" for America/New_York.
    static func place(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }
}

/// P49: everything the orientation turn says, gathered SwarmHub-side from what the app already knows (no Hermes changes).
/// Names and descriptions only: never a key, and of the instructions only the title and the first lines.
struct OrientationContext: Equatable, Sendable {
    struct Teammate: Equatable, Sendable { var name: String; var profile: String?; var description: String }
    var userName = "Konrad"
    var name: String; var profile: String?; var description = ""
    var instructionsTitle: String?; var instructionsLines: [String] = []
    var skills: [String] = []
    /// "Gmail (konrad@work.example, konrad@home.example)".
    var apps: [String] = []
    var teammates: [Teammate] = []
    var coordinator: Teammate?
    /// The team the coordinator works in (a team request goes there); nil: plain SwarmHub messaging.
    var coordinatorTeam: String?
    var timeZone: TimeZone = .current
    var quietHours = QuietHours()
}

enum OrientationPrompt {
    static let maxLines = 3, maxLineLength = 160, maxTeammates = 12

    /// The title (first non-empty line, without a Markdown heading mark) and the next few non-empty lines, each cut short.
    static func excerpt(_ instructions: String) -> (title: String?, lines: [String]) {
        let lines = instructions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first else { return (nil, []) }
        let title = cut(first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
        return (title.isEmpty ? nil : title, lines.dropFirst().prefix(maxLines).map(cut))
    }

    private static func cut(_ line: String) -> String { line.count > maxLineLength ? String(line.prefix(maxLineLength - 1)) + "…" : line }

    /// A card field on one line: line breaks and runs of spaces collapse, and it is cut short, so a description can never
    /// add lines or steps of its own to the prompt.
    static func oneLine(_ text: String) -> String {
        cut(text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " "))
    }

    private static func who(_ mate: OrientationContext.Teammate) -> String {
        oneLine(mate.name) + (mate.profile.map { " (profile \($0))" } ?? "")
    }

    static func text(_ c: OrientationContext) -> String {
        let user = c.userName, place = QuietHours.place(c.timeZone), wake = QuietHours.clock(c.quietHours.end)
        var about = ["- Name: \(oneLine(c.name))" + (c.profile.map { " (profile \($0))" } ?? "")]
        about.append("- Description: \(c.description.isEmpty ? "none yet" : oneLine(c.description))")
        if let title = c.instructionsTitle {
            about.append("- Your instructions begin: \(title)" + c.instructionsLines.map { "\n    \($0)" }.joined()
                         + "\n  (only the first lines; the full text is in your profile)")
        } else { about.append("- Instructions: none written yet beyond your profile's defaults") }
        about.append("- SwarmHub skills installed: \(c.skills.isEmpty ? "none yet" : c.skills.joined(separator: ", "))")
        about.append("- Connected apps: \(c.apps.isEmpty ? "none yet" : c.apps.map(oneLine).joined(separator: "; "))")

        let mates = c.teammates.prefix(maxTeammates).map { "  - \(who($0))" + ($0.description.isEmpty ? "" : ": \(oneLine($0.description))") }
        var team = ["- Teammates:" + (mates.isEmpty ? " none yet" : "\n" + mates.joined(separator: "\n"))]
        team.append("- Coordinator: " + (c.coordinator.map(who) ?? "none (report to \(user) only)"))
        team.append("- \(user)'s time zone: \(c.timeZone.identifier). Quiet hours: \(c.quietHours.label) \(place) time; do not message \(user) then.")

        let tell: String
        if let coordinator = c.coordinator {
            let channel = c.coordinatorTeam.map { "a team request in the team \"\($0)\" (\(coordinator.name) works there)" }
                ?? "SwarmHub messaging (the swarmhub-messages skill: bot-msg to \(coordinator.profile ?? coordinator.name))"
            tell = "Tell \(coordinator.name), your coordinator, about the job through \(channel) and ask for confirmation. If you do not have the swarmhub-messages skill yet, say so: \(user) installs it from SwarmHub."
        } else {
            tell = "You have no coordinator yet: tell \(user) about the job here instead."
        }
        let report = c.coordinator.map { "to \($0.name) when the job is done, and to \(user)" } ?? "to \(user)"
        let steps = [
            "Greet \(user) in one line (\"Hi \(user), \(c.name) here\") and say in two or three lines what you will do here.",
            "Pick one concrete, read-only first job in your own area: survey what exists, what is built and what is missing. Start it now with your normal tools, or as a coding job (swarmhub-coding) if that fits better.",
            tell,
            "Say when you will report: \(report) outside quiet hours (say the time, e.g. \"after \(wake) \(place)\"). Then deliver a short plan with the next queued tasks.",
            "Handle trouble yourself: restart a job that died, once; flag what you cannot reach (a private repository, a missing key or connection) and name what \(user) has to do.",
            "Make no changes beyond read-only work until \(user)\(c.coordinator.map { " or \($0.name)" } ?? "") says so."
        ]
        return """
        [SwarmHub orientation] You were just created in SwarmHub for \(user). This is your first message: orient yourself and start.

        About you
        \(about.joined(separator: "\n"))

        Your team
        \(team.joined(separator: "\n"))

        Do this now:
        \(steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

        Keep this reply short. Never print keys or secrets.
        """
    }
}
