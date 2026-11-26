import SwiftUI

struct NativeStepRow: View {
    typealias Step = HerdrClient.ThreadActivity.Details.Step
    let step: Step
    let runtime: HerdrClient.ChildRuntime
    let command: String?

    var body: some View {
        let parts = Self.parts(step.text, runtime: runtime, command: command)
        let style = Self.status(step.state)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: style.0).font(.caption).foregroundStyle(style.1)
                .frame(width: 14).help(step.state ?? "Status unavailable")
            Text(verbatim: parts.label).font(.callout).textSelection(.enabled)
            if let detail = parts.detail {
                Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }.accessibilityElement(children: .combine)
            .accessibilityValue(step.state ?? "Status unavailable")
    }

    static func parts(_ text: String, runtime: HerdrClient.ChildRuntime, command: String?) -> (label: String, detail: String?) {
        if !text.isEmpty && text == command { return ("Run command", text) }
        if runtime == .claude, let space = text.firstIndex(of: " ") {
            let tool = String(text[..<space])
            if ["Bash", "Read", "Edit", "Write", "Grep", "Glob"].contains(tool) {
                return (ActivityCopy.label(HerdrBackend.toolName(tool)), String(text[text.index(after: space)...]))
            }
        }
        if runtime == .opencode, let split = text.range(of: " · ") {
            return (String(text[..<split.lowerBound]), String(text[split.upperBound...]))
        }
        return (text, nil)
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
