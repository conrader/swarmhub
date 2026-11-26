import Foundation

/// Only a single-line draft beginning with a complete command token is executable.
enum SlashCommand: Equatable {
    case commands, goalUsage, invalidStepLimit, invalidBudget, start(String, stepLimit: Int? = nil, budgetUSD: Double? = nil, perGoal: Bool = false), status, stop

    static let stepLimitUsage = "Use /goal --steps N <objective>, with a positive whole number for N."

    static let budgetUsage = "Use --goal-budget USD for this goal or --budget USD for the whole OpenCode session."

    enum Name: String, CaseIterable {
        case goal = "/goal"
        case commands = "/commands"

        var usage: String {
            switch self {
            case .goal: "[--steps N] [--goal-budget USD | --budget USD] <objective> · status · stop"
            case .commands: "List chat commands"
            }
        }

        var insertion: String { rawValue + " " }
    }

    /// Also allow editing a limit or step count before the objective is typed.
    static func editableGoal(in draft: String) -> Self? {
        guard draft.hasPrefix("/goal "), parse(draft) != .status, parse(draft) != .stop,
              case .start(let marked, let steps, let budget, let perGoal) = parse(draft + " x") else { return nil }
        return .start(String(marked.dropLast()).trimmingCharacters(in: .whitespaces), stepLimit: steps, budgetUSD: budget, perGoal: perGoal)
    }

    func settingBudget(_ input: String, perGoal: Bool) -> String? {
        guard case .start(let objective, let steps, _, _) = self else { return nil }
        let amount = input.trimmingCharacters(in: .whitespaces)
        let flag = perGoal ? "--goal-budget" : "--budget"
        guard case .start(_, _, .some, _) = Self.parse("/goal " + flag + " " + amount + " check"),
              !amount.contains(where: \.isWhitespace) else { return nil }
        let stepOption = steps.map { "--steps \($0) " } ?? ""
        return "/goal " + stepOption + flag + " " + amount + " " + objective
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
            default:
                var rest = argument[...]
                var steps: Int?
                var budget: Double?
                var perGoal = false
                while !rest.isEmpty {
                    let fields = rest.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                    let flag = fields[0].replacingOccurrences(of: "—", with: "--").replacingOccurrences(of: "–", with: "--")
                    if flag.hasPrefix("--budget=") || flag.hasPrefix("--goal-budget=") { return .invalidBudget }
                    if flag.hasPrefix("--steps=") { return .invalidStepLimit }
                    switch flag {
                    case "--steps":
                        guard fields.count == 3, steps == nil, let n = Int(fields[1]), n > 0 else { return .invalidStepLimit }
                        steps = n
                    case "--budget", "--goal-budget":
                        guard fields.count == 3, budget == nil, fields[1].wholeMatch(of: #/[0-9]+(?:\.[0-9]{1,2})?/#) != nil,
                              let usd = Double(fields[1]), usd.isFinite, usd > 0 else { return .invalidBudget }
                        budget = usd
                        perGoal = flag == "--goal-budget"
                    default: return .start(String(rest), stepLimit: steps, budgetUSD: budget, perGoal: perGoal)
                    }
                    rest = fields[2]
                }
                return .goalUsage
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
        case .goalUsage?: self = .edit("/goal ", hint: "Enter an objective, or use /goal --steps 3 <objective> to limit goal turns.")
        case .invalidBudget?: self = .notice(SlashCommand.budgetUsage)
        case .invalidStepLimit?: self = .notice(SlashCommand.stepLimitUsage)
        case .stop?: self = .goal(.stop)
        case .status?: self = .goal(.status)
        case let command?: self = .goal(command)
        }
    }
}
