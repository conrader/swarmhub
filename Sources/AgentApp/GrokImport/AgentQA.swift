import AppKit
import SwiftUI

/// A private sample workspace driven over standard input. Each request finishes before the next is read.
@MainActor final class AgentQA {
    typealias Command = [String: String]
    static let commands = ["inspect", "open", "draft", "send", "details", "screen", "pin", "unpin", "appearance", "viewport", "capture", "expect", "finding"]
    let store: AppStore
    let directory: URL
    var screen = "workspace"
    var scheme = ColorScheme.dark
    var size = NSSize(width: 1120, height: 760)
    var history: [Command] = []
    var findings: [[String: Any]] = []
    var rejected = 0
    var failedChecks = 0

    init(output: URL) throws {
        directory = output.appending(path: "qa-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appending(path: "fixture", directoryHint: .isDirectory)
        let suite = scratch.appending(path: "settings").path
        guard let defaults = UserDefaults(suiteName: suite) else { throw QAError("Could not create sample preferences.") }
        store = AppStore(demoMode: true, storeURL: scratch.appending(path: "store.json"), autoStart: false,
                         backendFactory: { _ in MockBackend() }, keyStore: MemoryKeyStore(), defaults: defaults)
        for bot in store.bots { bot.notificationsEnabled = false }
        if let first = store.bots.first { store.open(first) }
    }

    static func run(arguments: [String]) -> Int32 {
        if arguments.contains("--help") {
            print("""
            AgentApp --agent-qa OUTPUT_DIRECTORY [--hunt]
            Run --hunt for built-in checks, or send JSON objects on stdin. Each result is one JSON line.
            Example: {"action":"open","bot":"Mira"}
            Actions: inspect, open(bot), draft(text), send(optional text), pin, unpin,
              appearance(value: dark/light), viewport(width,height), details(value: show/hide),
              screen(value: workspace/whatsNew), capture, expect(field,value), finding(kind,text).
            Fields are strings. Expect supports selected, draft, pinned, unread, lastRole, and contains (with text).
            Findings take the kind bug or improvement. Close stdin to save report.json beside replay.jsonl.
            """)
            return 0
        }
        guard let flag = arguments.firstIndex(of: "--agent-qa"),
              let path = arguments.dropFirst(flag + 1).first, !path.hasPrefix("--") else {
            print("Usage: AgentApp --agent-qa OUTPUT_DIRECTORY [--hunt]. Without --hunt, send JSON commands on stdin.")
            return 64
        }
        return HeadlessRunLoop.wait {
            do {
                let session = try AgentQA(output: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
                try session.emit(["event": "ready", "protocol": 1, "directory": session.directory.path,
                                  "actions": commands, "state": session.state])
                if arguments.contains("--hunt") {
                    for command in sampleHunt { try await session.step(command) }
                } else {
                    for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                        let command: Command
                        do { command = try JSONDecoder().decode(Command.self, from: Data(line.utf8)) }
                        catch {
                            session.rejected += 1
                            try session.emit(["event": "error", "error": "Expected a JSON object with string fields."])
                            continue
                        }
                        try await session.step(command)
                    }
                }
                let report: [String: Any] = ["protocol": 1, "version": AppBuildInfo.current().version,
                    "steps": session.history.count, "failedChecks": session.failedChecks,
                    "rejectedCommands": session.rejected, "findings": session.findings]
                let reportURL = session.directory.appending(path: "report.json")
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
                try session.emit(["event": "finished", "report": reportURL.path, "findings": session.findings.count])
                return session.rejected > 0 || session.failedChecks > 0 ? 1 : 0
            } catch {
                FileHandle.standardError.write(Data(("Agent QA: " + error.localizedDescription + "\n").utf8))
                return 1
            }
        }
    }

    /// State an agent can use to decide its next action, without parsing a screenshot.
    var state: [String: Any] {
        let bot = store.selectedBot
        return ["selected": bot?.name ?? "", "bots": store.bots.map { ["name": $0.name, "unread": $0.unreadCount, "pinned": store.isPinned($0.id)] as [String: Any] },
                "draft": bot.map { store.drafts.text(for: $0.id) } ?? "", "details": store.showInfo, "screen": screen,
                "messages": bot?.messages.map { ["role": $0.role.rawValue, "text": $0.content] } ?? [],
                "appearance": scheme == .dark ? "dark" : "light", "width": Int(size.width), "height": Int(size.height)]
    }

    private func emit(_ object: [String: Any]) throws {
        var bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }

    private func step(_ command: Command) async throws {
        history.append(command)
        let line = try JSONSerialization.data(withJSONObject: command, options: [.sortedKeys]) + Data([10])
        let replay = directory.appending(path: "replay.jsonl")
        if history.count == 1 { try line.write(to: replay) }
        else {
            let file = try FileHandle(forWritingTo: replay)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: line)
        }
        do {
            var response = try await perform(command)
            response["step"] = history.count
            response["event"] = "result"
            response["state"] = state
            try emit(response)
        } catch let error as QAError {
            rejected += 1
            try emit(["event": "error", "step": history.count, "error": error.localizedDescription])
        }
    }

    private func perform(_ command: Command) async throws -> [String: Any] {
        func field(_ key: String) throws -> String {
            guard let value = command[key], !value.isEmpty else { throw QAError("Missing " + key) }
            return value
        }
        guard let bot = store.selectedBot else { throw QAError("No chat selected.") }
        switch try field("action") {
        case "inspect": break
        case "open":
            let name = try field("bot")
            guard let target = store.bots.first(where: { $0.name == name }) else { throw QAError("Unknown bot: " + name) }
            store.open(target)
            screen = "workspace"
        case "screen":
            let name = try field("value")
            guard ["workspace", "whatsNew"].contains(name) else { throw QAError("Choose workspace or whatsNew.") }
            screen = name
        case "details":
            switch try field("value") {
            case "show": store.showInfo = true
            case "hide": store.showInfo = false
            default: throw QAError("Choose show or hide.")
            }
        case "draft":
            guard let text = command["text"] else { throw QAError("Missing text") }
            store.drafts.set(text, for: bot.id)
        case "pin": store.setPinned(bot.id, true)
        case "unpin": store.setPinned(bot.id, false)
        case "send":
            let text = command["text"] ?? store.drafts.text(for: bot.id)
            guard store.send(text: text) else { throw QAError(store.errorMessage ?? "Send was declined.") }
            store.drafts.set("", for: bot.id)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while !store.isIdle(bot), clock.now < deadline { try await Task.sleep(for: .milliseconds(40)) }
            if !store.isIdle(bot) { return try await record("bug", "Sample reply did not finish within ten seconds.", failed: true) }
        case "appearance":
            switch try field("value") {
            case "light": scheme = .light
            case "dark": scheme = .dark
            default: throw QAError("Choose light or dark.")
            }
        case "viewport":
            guard let w = Int(try field("width")), let h = Int(try field("height")),
                  (980...2560).contains(w), (620...1600).contains(h) else { throw QAError("Use 980–2560 points wide and 620–1600 high.") }
            size = NSSize(width: w, height: h)
        case "capture": return ["screenshot": try await capture()]
        case "expect":
            guard let expected = command["value"] else { throw QAError("Missing value") }
            let actual: String
            switch try field("field") {
            case "selected": actual = bot.name
            case "pinned": actual = String(store.isPinned(bot.id))
            case "draft": actual = store.drafts.text(for: bot.id)
            case "unread": actual = String(bot.unreadCount)
            case "lastRole": actual = bot.messages.last?.role.rawValue ?? ""
            case "contains":
                let text = try field("text")
                actual = String(bot.messages.contains { $0.content.contains(text) })
            default: throw QAError("Unknown expectation field.")
            }
            if actual != expected {
                return try await record("bug", "\(command["field"] ?? "") expected “\(expected)”, observed “\(actual)”.", failed: true)
            }
            return ["passed": true]
        case "finding":
            let kind = try field("kind")
            guard ["bug", "improvement"].contains(kind) else { throw QAError("Choose bug or improvement.") }
            return try await record(kind, field("text"), failed: false)
        default: throw QAError("Unknown action. Available actions: " + Self.commands.joined(separator: ", "))
        }
        return [:]
    }

    private func capture() async throws -> String {
        let filename = String(format: "step-%04d.png", history.count)
        let image: Data?
        if screen == "whatsNew" {
            image = await SnapshotRenderer.png(WhatsNewPane(), size: size, scale: 1, scheme: scheme)
        } else {
            image = await SnapshotRenderer.contentPNG(store: store, size: size, scale: 1, scheme: scheme)
        }
        guard let data = image else {
            throw QAError("The Mac could not render the workspace.")
        }
        try data.write(to: directory.appending(path: filename), options: .atomic)
        return filename
    }

    private func record(_ kind: String, _ text: String, failed: Bool) async throws -> [String: Any] {
        var finding: [String: Any] = ["kind": kind, "text": text, "step": history.count, "source": failed ? "check" : "agent"]
        if failed { failedChecks += 1 }
        do { finding["screenshot"] = try await capture() }
        catch { finding["captureError"] = error.localizedDescription }
        findings.append(finding)
        return ["finding": finding]
    }
}

private struct QAError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}
