import SwiftUI

/// The live reply's Thinking, Typing or Working phase and current action, refreshed every second.
struct ActivityLiveLine: View {
    @ObservedObject var message: ChatMessage
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(ActivityCopy.liveLine(message.activity, since: message.createdAt, lastText: message.lastTextAt, now: context.date))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if ChatActivityPhase.current(message.activity, lastText: message.lastTextAt, now: context.date) == .working,
                   let preview = message.activity?.current?.preview {
                    Text(preview).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// P27 D9: after the turn, a folded "12 steps · 4 m 52 s" row that opens to the list of steps.
struct ActivityStepsRow: View {
    @ObservedObject var message: ChatMessage
    @State private var expanded: Bool
    init(message: ChatMessage, expanded: Bool = false) { self.message = message; _expanded = State(initialValue: expanded) }

    var body: some View {
        if let activity = message.activity, let summary = ActivityCopy.summary(activity, since: message.createdAt) {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.system(size: 9, weight: .semibold))
                        Text(summary).monospacedDigit()
                        if activity.steps.contains(where: \.failed) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain).help(expanded ? "Hide steps" : "Show what \(summary.hasPrefix("1 step") ? "this step was" : "these steps were")")
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        if activity.total > activity.steps.count { Text("Earlier \(activity.total - activity.steps.count) steps not kept").font(.caption2).foregroundStyle(.tertiary) }
                        ForEach(Array(activity.steps.enumerated()), id: \.offset) { _, step in StepLine(step: step, number: activity.number(of: step)) }
                    }.padding(.leading, 14)
                }
            }
        }
    }
}

private struct StepLine: View {
    let step: ToolStep; let number: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number)").font(.caption2).foregroundStyle(.tertiary).frame(minWidth: 16, alignment: .trailing).monospacedDigit()
            Image(systemName: step.failed ? "xmark.circle.fill" : "checkmark.circle").font(.caption2).foregroundStyle(step.failed ? Color.red : Color.secondary)
            Text(ActivityCopy.label(step.name)).font(.caption)
            Text(step.name).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            if let preview = step.preview { Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if let end = step.finishedAt { Text(ActivityCopy.duration(end.timeIntervalSince(step.startedAt))).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
        }
    }
}
