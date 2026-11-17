import Foundation

/// What a turn on Herdr is waiting for right now, as the chat says it under the reply until text or a tool step says
/// more. It is what the bridge reports, never a guess: the agent program is being started, the message is on its way
/// or delivered, the agent says it is working, it is waiting for the person in its terminal, or it has finished and
/// its reply is being saved. `program` is the server's name for the agent program (a template's `harness`).
/// A status travels through the chat's stream as its `code` (`AgentEvent.status`), and the reply row keeps that under
/// `TurnKey.agent` while the turn runs. Foundation only, like the rest of the Herdr client.
enum HerdrTurnStatus: Equatable, Sendable {
    /// The message is on its way to the server.
    case sending
    /// The agent program is starting: this turn launched it, or it was started ahead of time and is not ready yet.
    case starting(program: String?)
    /// The agent has the message and has not said that it works on it yet.
    case delivered(program: String?)
    case working(program: String?)
    /// The agent shows a prompt in its terminal and waits there for the person.
    case blocked(program: String?)
    /// The agent says it is done; its reply is being saved.
    case finishing
    case failing(program: String?)

    private static let lead = "herdr."

    /// "herdr.starting|Codex": what the chat's stream and the reply row carry.
    var code: String {
        let (name, program): (String, String?) = switch self {
        case .sending: ("sending", nil)
        case .starting(let program): ("starting", program)
        case .delivered(let program): ("delivered", program)
        case .working(let program): ("working", program)
        case .blocked(let program): ("blocked", program)
        case .finishing: ("finishing", nil)
        case .failing(let program): ("failing", program)
        }
        return Self.lead + name + (program.map { "|" + $0 } ?? "")
    }

    /// nil for any other status text a backend sends.
    init?(code: String) {
        guard code.hasPrefix(Self.lead) else { return nil }
        let parts = code.dropFirst(Self.lead.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let program = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        switch parts.first.map(String.init) {
        case "sending": self = .sending
        case "starting": self = .starting(program: program)
        case "delivered": self = .delivered(program: program)
        case "working": self = .working(program: program)
        case "blocked": self = .blocked(program: program)
        case "finishing": self = .finishing
        case "failing": self = .failing(program: program)
        default: return nil
        }
    }

    /// The live line's first words: "Starting Codex…".
    var line: String {
        switch self {
        case .sending: "Sending…"
        case .starting(let program): "Starting \(program ?? "the agent")…"
        case .delivered(let program): "Delivered to \(program ?? "the agent")…"
        case .working(let program): "\(program ?? "The agent") is working…"
        case .blocked(let program): "\(program ?? "The agent") is waiting for you in its terminal"
        case .finishing: "Finishing…"
        case .failing(let program): "\(program ?? "The agent") reported an error"
        }
    }

    /// What the line adds for a state that needs a word of explanation.
    var note: String? {
        if case .starting = self { return Self.firstReplyNote }
        return nil
    }

    static let firstReplyNote = "the first reply takes longer"

    /// The agent is not moving and only the person can change that: the line says so whatever else the reply shows
    /// (a tool step that waits for a permission is still "running").
    var needsPerson: Bool { if case .blocked = self { true } else { false } }

    /// The status for what the agent last reported (`HerdrClient.Agent.Status.state`). `began`: the agent has shown
    /// work in this turn (it said "working", ran a tool, or wrote text). `starting`: this turn started the agent, or
    /// found it still starting. An agent that is "done" or "idle" before it began has not taken the message yet.
    static func of(agentState state: String, program: String?, began: Bool, starting: Bool) -> HerdrTurnStatus {
        switch state {
        case "working": .working(program: program)
        case "blocked": .blocked(program: program)
        case "error": .failing(program: program)
        case "done", "idle": began ? .finishing : (starting ? .starting(program: program) : .delivered(program: program))
        default: began ? .working(program: program) : (starting ? .starting(program: program) : .delivered(program: program))
        }
    }
}
