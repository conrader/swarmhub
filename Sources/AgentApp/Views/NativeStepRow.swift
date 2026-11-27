import SwiftUI

struct NativeStepRow: View {
    typealias Step = HerdrClient.ThreadActivity.Details.Step
    let step: Step
    let runtime: HerdrClient.ChildRuntime
    let command: String?
    let sessionWorking: Bool

    var body: some View {
        let running = sessionWorking && Self.isRunning(step.state)
        let parts = Self.parts(step, runtime: runtime, command: command, running: running)
        let style = Self.status(step.state)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.0).font(.caption).foregroundStyle(style.1)
                .frame(width: 14).help(step.state ?? "Status unavailable")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: parts.label).font(.callout).textSelection(.enabled)
                    HelperStepDuration(start: step.startedMs, end: step.completedMs, duration: step.durationMs, running: running)
                }
                if let detail = parts.detail {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }.accessibilityElement(children: .combine)
            .accessibilityValue(step.state ?? "Status unavailable")
    }

    static func parts(_ step: Step, runtime: HerdrClient.ChildRuntime, command: String?, running: Bool) -> (label: String, detail: String?) {
        let text = step.text
        let commandLabel = running ? "Running command" : "Command"
        if !text.isEmpty && (step.tool == "shell" || text == command) { return (commandLabel, text) }
        if runtime == .claude, let space = text.firstIndex(of: " ") {
            let tool = String(text[..<space])
            if ["Bash", "Read", "Edit", "Write", "Grep", "Glob"].contains(tool) {
                return (tool == "Bash" ? commandLabel : ActivityCopy.label(HerdrBackend.toolName(tool)), String(text[text.index(after: space)...]))
            }
        }
        if runtime == .opencode, let split = text.range(of: " · ") {
            return (String(text[..<split.lowerBound]), String(text[split.upperBound...]))
        }
        return (text, nil)
    }

    static func isRunning(_ state: String?) -> Bool {
        ["running", "working", "inprogress", "executing"].contains(state?.lowercased())
    }

    static func status(_ state: String?) -> (String, Color) {
        switch state?.lowercased() {
        case "finished", "completed", "success", "succeeded": ("checkmark.circle", AppColor.sage)
        case "running", "working", "inprogress", "executing": ("circle.dotted", .accentColor)
        case "failed", "error", "declined": ("xmark.circle", .red)
        case "cancelled", "canceled", "interrupted", "stopped": ("stop.circle", .secondary)
        default: ("circle", .secondary)
        }
    }
}

/// A command can finish between polls, arrive without a start event, or outlive its last snapshot.
struct HelperStepDuration: View {
    let start: Int64?
    let end: Int64?
    var duration: Int64? = nil
    let running: Bool

    nonisolated static func milliseconds(start: Int64?, end: Int64?, duration: Int64?, now: Int64?) -> Int64? {
        if let duration, duration >= 0 { return duration }
        guard let start, start > 0, let stop = end ?? now, stop >= start else { return nil }
        return stop - start
    }

    var body: some View {
        if running, let start, start > 0, end == nil, duration == nil {
            TimelineView(.periodic(from: Date(timeIntervalSince1970: Double(start) / 1000), by: 1)) { tick in
                caption(now: Int64(tick.date.timeIntervalSince1970 * 1000))
            }
        } else {
            caption(now: nil)
        }
    }

    @ViewBuilder private func caption(now: Int64?) -> some View {
        if let ms = Self.milliseconds(start: start, end: end, duration: duration, now: now) {
            Text("· " + ActivityCopy.duration(Double(ms) / 1000, compact: true))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
