import Foundation

/// Only a single-line draft beginning with a complete command token is executable.
enum SlashCommand: Equatable {
    case commands, goalUsage, start(String), status, stop

    enum Name: String, CaseIterable {
        case goal = "/goal"
        case commands = "/commands"

        var usage: String {
            switch self {
            case .goal: "<objective> · status · stop"
            case .commands: "List chat commands"
            }
        }

        var insertion: String { rawValue + " " }
    }

    static func parse(_ draft: String) -> Self? {
        guard draft.hasPrefix("/"), !draft.contains(where: \.isNewline) else { return nil }
        let parts = draft.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let token = parts.first, let name = Name(rawValue: String(token)) else { return nil }
        let argument = parts.dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch name {
        case .commands: return argument.isEmpty ? .commands : nil
        case .goal:
            switch argument {
            case "": return .goalUsage
            case "status": return .status
            case "stop": return .stop
            default: return .start(argument)
            }
        }
    }
}

/// Selection only edits the draft. Exact command names are ready for submission.
struct SlashMenu {
    private var dismissed: String?
    private(set) var index = 0

    func choices(for draft: String) -> [SlashCommand.Name] {
        guard draft.hasPrefix("/"), draft != dismissed, SlashCommand.Name(rawValue: draft) == nil else { return [] }
        return SlashCommand.Name.allCases.filter { $0.rawValue.hasPrefix(draft) }
    }

    mutating func reset() { index = 0; dismissed = nil }
    mutating func dismiss(_ draft: String) { dismissed = draft }
    mutating func move(_ offset: Int, draft: String) -> Bool {
        let count = choices(for: draft).count
        guard count > 0 else { return false }
        index = (index + offset + count) % count
        return true
    }

    func selection(for draft: String) -> SlashCommand.Name? {
        let matches = choices(for: draft)
        return matches.indices.contains(index) ? matches[index] : matches.first
    }
}

/// The submit button and Return share this routing before chat delivery (including
/// steering an active turn). Choosing a menu item never enters this path.
enum ComposerSubmission: Equatable {
    case message
    case edit(String, hint: String?)
    case notice(String)
    case goal(SlashCommand)

    init(draft: String, hasAttachments: Bool) {
        switch SlashCommand.parse(draft) {
        case nil: self = .message
        case .commands?: self = .edit("/", hint: nil)
        case .goalUsage?: self = .edit("/goal ", hint: "Enter an objective after /goal.")
        case _ where hasAttachments: self = .notice("Remove the attachments to use a goal command.")
        case let command?: self = .goal(command)
        }
    }
}
