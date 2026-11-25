import Foundation

/// An agent that has stopped at a question in its terminal (may it run this command, does it trust this folder) and
/// does nothing until the person answers there. `question` is what its terminal shows, read from the server; empty
/// until it was read, or when the server could not show it. Foundation only.
struct HerdrPrompt: Equatable, Sendable {
    var reviewDescription: String? = nil
    /// The server's name for the agent program ("Codex"); nil when it gave none.
    var program: String?
    var question = ""
    /// The terminal to answer in, once the server's list was read.
    var agent: HerdrClient.AgentRef?
    var since: Date

    /// How many lines of the terminal the chat shows: enough for a command and its choices.
    static let lines = 16

    var title: String { "\(program ?? "The agent") is waiting for your answer" }
    static let detail = "It asked this in its terminal and does nothing until you answer there."
    static let unread = "Nothing could be read from its terminal. Open it to see what it asks."
    /// The bot's line in the sidebar while it waits and no turn says so itself.
    static let sidebar = "Waiting for your answer"
    /// What the notification says; the bot's name is its title.
    var notice: String { "\(program ?? "Its agent") is asking a question and waits for your answer." }

    /// The question as the chat shows it (`HerdrAICheck.question`): the lines with words, without the frames.
    static func actionable(kind: String?, screen: String) -> Bool {
        let text = question(from: screen).lowercased()
        let tail = text.split(separator: "\n").suffix(3)
        if tail.contains(where: { $0.contains("? for shortcuts") || $0.contains("for help with commands") }),
           !tail.contains(where: { $0.contains("esc to cancel") || $0.contains("yes,") || $0.contains("no,") }) {
            return false
        }
        if ["trust this folder?", "do you trust the files", "do you trust this folder", "do you trust the contents", "yes, i trust this folder",
            "do you want to proceed?", "do you want to make this edit", "do you want to allow", "would you like to run the following command",
            "allow this command", "allow once", "yes, and don’t ask again", "yes, and don't ask again"].contains(where: text.contains) {
            return true
        }
        if text.contains("esc to cancel") && text.contains("yes") && text.contains("no") { return true }
        guard let kind else { return false }
        // "auth": a program that asks how to sign in. "question": one that asks the person something itself.
        return ["permission", "permission_request", "trust", "trust_dialog", "input_request", "user_input", "approval", "auth", "question"].contains(kind.lowercased())
    }

    static func review(for agent: HerdrClient.Agent, program: String?, question: String) -> String? {
        let kind = agent.status?.kind?.lowercased() ?? ""
        let commandPrompt = question.localizedCaseInsensitiveContains("would you like to run the following command")
        guard program == "Codex", commandPrompt || ["permission", "permission_request", "approval"].contains(kind) else {
            return nil
        }
        switch agent.codexReviewer {
        case "user": return "A human decision is required because this Codex session routes permission requests to you."
        case "auto_review": return "Codex has automatic review enabled and is asking you to decide this request in its terminal."
        default: return "A human decision is required because Codex is waiting at a permission prompt. Its reviewer setting has not been reported."
        }
    }

    static func question(from screen: String) -> String { HerdrAICheck.question(from: screen, lines: lines) }
}

/// How the person gets to the terminal of an agent that waits, by where its server is.
enum HerdrPromptAnswer: Equatable, Sendable {
    /// A script for Terminal: Herdr Core's own viewer on this Mac, or the same over SSH on the server.
    case terminal(script: String)
    /// A server reached by an address someone else forwards: its workspace page, where "Take over" opens the terminal.
    case browser(URL)

    var button: String { if case .terminal = self { "Answer in Terminal" } else { "Open in Browser" } }
    var help: String {
        switch self {
        case .terminal: "Opens its terminal in a Terminal window. Answer there; closing the window leaves it running."
        case .browser: "Opens the server's page in your browser. Choose the bot there, then Take over, and answer."
        }
    }

    /// An address the server gave is used in a command line only when it is a plain terminal name (`t7`, `box/t7`).
    static func isSafe(address: String) -> Bool {
        !address.isEmpty && !address.hasPrefix("-") && address.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// The command that puts a terminal on the agent's, on the server itself: Herdr Core's viewer from where setup
    /// installs it, else from the path.
    static func remoteCommand(address: String) -> String {
        "for c in \"$HOME/.local/bin/hc\" \"$HOME/.local/bin/herdr-core\"; do if [ -x \"$c\" ]; then exec \"$c\" attach \(address); fi; done; exec hc attach \(address)"
    }

    /// nil when there is no way the app can offer (an address that is not a terminal's, a server with no usable address).
    /// `localScript`: the script for this Mac (`AppStore.terminalScript`); `sshOptions`: the options every ssh call of
    /// the app to that server shares (`HerdrTunnel.options`).
    static func plan(server: HerdrServer, address: String, name: String, localScript: (String) -> String, sshOptions: [String]?) -> HerdrPromptAnswer? {
        switch server.kind {
        case .local:
            return isSafe(address: address) ? .terminal(script: localScript(address)) : nil
        case .ssh:
            guard isSafe(address: address), let sshOptions else { return nil }
            let call = (["/usr/bin/ssh", "-t"] + sshOptions + ["--", server.sshHost, remoteCommand(address: address)]).map(quoted).joined(separator: " ")
            return .terminal(script: ["#!/bin/sh", "# Opens \(name)'s own terminal on \(server.name) so you can answer its question. Close the window when you are done.",
                                      "exec \(call)"].joined(separator: "\n") + "\n")
        case .address:
            return HerdrClient.validatedBaseURL(server.address).map { .browser($0) }
        }
    }
}
