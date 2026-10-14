import Foundation

/// P27 D9: one tool event from a backend stream. `preview` is already one line, redacted and truncated by the backend;
/// `callID` pairs a finish with its start when the stream carries one.
struct ToolEvent: Sendable, Equatable {
    enum Phase: String, Sendable { case started, progress, completed, failed }
    var phase: Phase; var name: String; var preview: String? = nil; var callID: String? = nil

    static let previewLimit = 80

    /// A preview safe to show and store: first line only, secrets removed (the shared filter and the connection's own
    /// key), at most `previewLimit` characters. Nil when nothing is left.
    static func preview(_ raw: String?, key: String = "") -> String? {
        guard let raw else { return nil }
        var text = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if key.count >= 4 { text = text.replacingOccurrences(of: key, with: "[key]") }
        text = GrokTemplateParser.redactSecrets(text).text
        // `API_SERVER_KEY=…`, `token: …`: the value after any key-ish name goes too.
        text = text.replacingOccurrences(of: #"(?i)\b([A-Z0-9_.-]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[A-Z0-9_.-]*\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)"#,
                                         with: "$1[removed]", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return text.count > previewLimit ? String(text.prefix(previewLimit - 1)) + "…" : text
    }
}

/// One step of a reply: a tool the bot ran, what it ran it on, when, and whether it failed.
struct ToolStep: Codable, Equatable, Sendable {
    var name: String; var preview: String?; var startedAt: Date; var finishedAt: Date?; var failed = false; var callID: String?
    var isRunning: Bool { finishedAt == nil }
}

/// The ordered steps of one assistant reply, kept with the message. Only the last `limit` steps are kept; `total` still
/// counts every one, so the folded row says how many there were.
struct ToolActivity: Codable, Equatable, Sendable {
    static let limit = 50
    var steps: [ToolStep] = []; var total = 0; var endedAt: Date?

    /// Internal tools (`_thinking`) are not steps.
    static func isShown(_ name: String) -> Bool { !name.isEmpty && !name.hasPrefix("_") }

    mutating func apply(_ event: ToolEvent, at now: Date) {
        guard Self.isShown(event.name) else { return }
        switch event.phase {
        case .started:
            if let id = event.callID, steps.contains(where: { $0.callID == id }) { return }
            steps.append(ToolStep(name: event.name, preview: event.preview, startedAt: now, callID: event.callID)); total += 1
            if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
        case .progress:
            if let index = match(event), steps[index].preview == nil { steps[index].preview = event.preview }
        case .completed, .failed:
            guard let index = match(event) else { return }
            steps[index].finishedAt = now; steps[index].failed = event.phase == .failed
            if event.preview != nil, steps[index].preview == nil { steps[index].preview = event.preview }
        }
    }

    /// The running step an event belongs to: same call id, else the oldest running step of that tool, else the newest running one.
    private func match(_ event: ToolEvent) -> Int? {
        if let id = event.callID, let index = steps.lastIndex(where: { $0.callID == id && $0.isRunning }) { return index }
        return steps.firstIndex { $0.isRunning && $0.name == event.name } ?? steps.lastIndex { $0.isRunning }
    }

    /// The turn ended: every step still open ends with it.
    mutating func finish(at now: Date) {
        endedAt = now
        for index in steps.indices where steps[index].isRunning { steps[index].finishedAt = now }
    }

    var current: ToolStep? { steps.last { $0.isRunning } }

    /// 1-based number of `step` among all `total` steps (older ones may have been dropped).
    func number(of step: ToolStep) -> Int {
        guard let index = steps.lastIndex(of: step) else { return total }
        return total - (steps.count - 1 - index)
    }
}

/// The words the chat and the sidebar use for activity (plain, simple copy).
enum ActivityCopy {
    /// "Running a command", "Reading a file"; a tool without plain words is "Running <tool>".
    static func label(_ tool: String) -> String {
        let name = tool.lowercased()
        let plain: [(keys: [String], text: String)] = [
            (["terminal", "shell", "bash", "exec_command", "execute_code", "process"], "Running a command"),
            (["read_file", "search_files", "file_read", "list_files"], "Reading a file"),
            (["write_file", "patch", "edit_file", "file_write"], "Editing a file"),
            (["web_search", "search"], "Searching the web"),
            (["web_extract", "browser_navigate", "browser", "fetch"], "Reading a web page"),
            (["skills_list", "skill_view", "skill_manage"], "Reading its skills"),
            (["memory"], "Updating its memory"),
            (["todo"], "Updating its to-do list"),
            (["delegate_task"], "Handing off a task"),
            (["image_generate"], "Making an image"),
            (["send_message"], "Sending a message")
        ]
        if let match = plain.first(where: { $0.keys.contains(name) }) { return match.text }
        if name.hasPrefix("browser_") { return "Using the browser" }
        return "Running \(tool)"
    }

    /// "1 m 12 s", "45 s", "1 h 3 m".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600) h \(total % 3600 / 60) m" }
        if total >= 60 { return "\(total / 60) m \(total % 60) s" }
        return "\(total) s"
    }

    /// While streaming: "Running a command · step 3 · 1 m 12 s"; between steps "Working… · 3 steps · 1 m 12 s".
    static func liveLine(_ activity: ToolActivity?, since start: Date, now: Date) -> String {
        let elapsed = duration(now.timeIntervalSince(start))
        guard let activity, activity.total > 0 else { return "Working… · \(elapsed)" }
        if let step = activity.current { return "\(label(step.name)) · step \(activity.number(of: step)) · \(elapsed)" }
        return "Working… · \(steps(activity.total)) · \(elapsed)"
    }

    /// After the turn: "12 steps · 4 m 52 s"; nil when the reply used no tools.
    static func summary(_ activity: ToolActivity?, since start: Date) -> String? {
        guard let activity, activity.total > 0 else { return nil }
        let end = activity.endedAt ?? activity.steps.compactMap(\.finishedAt).max() ?? start
        return "\(steps(activity.total)) · \(duration(end.timeIntervalSince(start)))"
    }

    static func steps(_ count: Int) -> String { count == 1 ? "1 step" : "\(count) steps" }

    static let quietAfter: TimeInterval = 60

    /// The sidebar's preview line for a reply still running `quietAfter` after its last text (or its start) with a
    /// step: "Working: terminal · ls -la", "Working: terminal …". Nil otherwise.
    static func sidebarLine(_ activity: ToolActivity?, started: Date, lastText: Date?, now: Date) -> String? {
        guard now.timeIntervalSince(max(started, lastText ?? started)) >= quietAfter,
              let step = activity?.current ?? activity?.steps.last else { return nil }
        return "Working: \(step.name)" + (step.preview.map { " · \($0)" } ?? " …")
    }
}
