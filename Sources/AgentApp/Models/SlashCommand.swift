import Foundation

/// P45: the composer's `/` commands. SwarmHub runs them itself: over the API path Hermes receives "/goal …" as plain
/// text (2026-10-15, box row 21), so nothing here is passed through to the bot.
enum SlashCommand: String, CaseIterable, Identifiable, Sendable {
    case help, new, model, stop, retry, status, goal, subgoal, loop, heartbeat
    var id: String { rawValue }
    var name: String { "/" + rawValue }
    /// The commands the menu offers (and the only ones run; anything else is sent as text).
    static let menu: [SlashCommand] = [.help, .new, .model, .stop, .retry, .status, .goal, .subgoal, .loop, .heartbeat]

    /// What the menu shows after the name.
    var usage: String {
        switch self {
        case .help: ""
        case .new: ""
        case .model: "<name>"
        case .stop: ""
        case .retry: ""
        case .status: ""
        case .goal: "<text> | pause | resume | clear | status"
        case .subgoal: "<text> | remove N | clear"
        case .loop: "[every] <prompt> [--times N] [--until <condition>]"
        case .heartbeat: "every <interval> [HH:MM–HH:MM] [<prompt>]"
        }
    }

    var summary: String {
        switch self {
        case .help: "List these commands"
        case .new: "Start a new thread from the last reply"
        case .model: "Switch this chat's model"
        case .stop: "Stop the reply, the goal and the loop"
        case .retry: "Retry the last reply"
        case .status: "Model, tokens, goal, loop and heartbeat"
        case .goal: "A goal the bot keeps working toward until done"
        case .subgoal: "Add a criterion to the running goal"
        case .loop: "Re-send a prompt on an interval while SwarmHub runs"
        case .heartbeat: "Check in on this chat on a schedule"
        }
    }

    /// Whether the command needs text after it to make sense when picked from the menu (Enter fills, not runs).
    var takesArguments: Bool { !usage.isEmpty }
}

/// What the composer's text is: a command, an unknown `/x` (sent as text after a warning), or a plain message.
enum SlashInput: Equatable {
    case command(SlashCommand, arguments: String)
    case unknown(String)
    case message

    static let unknownWarning = "Not a command — sent as a message"

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { self = .message; return }
        let head = trimmed.dropFirst().prefix { !$0.isWhitespace && !$0.isNewline }
        // A path ("/usr/bin is…") or a second slash is not a command attempt.
        guard !head.isEmpty, head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { self = .message; return }
        let arguments = trimmed.dropFirst(1 + head.count).trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = SlashCommand(rawValue: head.lowercased()), SlashCommand.menu.contains(command) { self = .command(command, arguments: arguments) }
        else { self = .unknown(String(head)) }
    }
}

/// The menu's rows for what is typed so far: shown while the draft is a single `/word` (no space yet).
enum SlashMenu {
    static func query(in text: String) -> String? {
        guard text.hasPrefix("/"), !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(text.dropFirst()).lowercased()
    }

    /// Commands whose name starts with the query first, then those that contain it; nil when the menu is closed.
    static func matches(for text: String, commands: [SlashCommand] = SlashCommand.menu) -> [SlashCommand]? {
        guard let query = query(in: text) else { return nil }
        if query.isEmpty { return commands }
        let prefix = commands.filter { $0.rawValue.hasPrefix(query) }
        return prefix + commands.filter { !$0.rawValue.hasPrefix(query) && $0.rawValue.contains(query) }
    }

    /// The draft after picking `command`: commands with arguments wait for them, the others are complete.
    static func completion(for command: SlashCommand) -> String { command.takesArguments ? command.name + " " : command.name }

    /// `/help`'s text: one line per command.
    static func helpText(_ commands: [SlashCommand] = SlashCommand.menu) -> String {
        (["Commands:"] + commands.map { command in
            let usage = command.usage.isEmpty ? "" : " " + command.usage
            return "\(command.name)\(usage) — \(command.summary)"
        }).joined(separator: "\n")
    }
}
