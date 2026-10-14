import SwiftUI

/// P27 D9, P29: what a reply did, one row for the whole turn. While it streams: "Running a command · step 3 · 1 m 12 s"
/// (refreshed every second); after it: "12 steps · 4 m 52 s". A chevron opens the steps whenever there is one, streaming
/// or not, and one view for both states keeps the row open when the turn ends.
struct ActivityRow: View {
    @ObservedObject var message: ChatMessage
    @State private var expanded: Bool
    init(message: ChatMessage, expanded: Bool = false) { self.message = message; _expanded = State(initialValue: expanded) }

    var body: some View {
        if ActivityCopy.isRowShown(message.activity, streaming: message.isStreaming) {
            VStack(alignment: .leading, spacing: 6) {
                if message.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in header(now: context.date) }
                } else {
                    header(now: .now)
                }
                if expanded, let activity = message.activity, ActivityCopy.canUnfold(activity) {
                    VStack(alignment: .leading, spacing: 4) {
                        if activity.total > activity.steps.count { Text("Earlier \(activity.total - activity.steps.count) steps not kept").font(.caption2).foregroundStyle(.tertiary) }
                        ForEach(Array(activity.steps.enumerated()), id: \.offset) { _, step in
                            StepLine(step: step, number: activity.number(of: step), running: ActivityCopy.isRunning(step, streaming: message.isStreaming))
                        }
                    }.padding(.leading, 14)
                }
            }
        }
    }

    @ViewBuilder private func header(now: Date) -> some View {
        let activity = message.activity
        if ActivityCopy.canUnfold(activity) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.system(size: 9, weight: .semibold))
                    status(activity, now: now)
                }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help(ActivityCopy.toggleHelp(expanded: expanded, total: activity?.total ?? 0, streaming: message.isStreaming))
        } else {
            HStack(spacing: 5) { status(activity, now: now) }.font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(_ activity: ToolActivity?, now: Date) -> some View {
        if message.isStreaming {
            ProgressView().controlSize(.mini)
            Text(ActivityCopy.liveLine(activity, since: message.createdAt, now: now)).monospacedDigit()
            if let preview = activity?.current?.preview {
                Text(preview).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        } else if let activity, let summary = ActivityCopy.summary(activity, since: message.createdAt) {
            Text(summary).monospacedDigit()
            if activity.steps.contains(where: \.failed) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }
}

private struct StepLine: View {
    let step: ToolStep; let number: Int; let running: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number)").font(.caption2).foregroundStyle(.tertiary).frame(minWidth: 16, alignment: .trailing).monospacedDigit()
            if running {
                ProgressView().controlSize(.mini).frame(width: 12.5, height: 11).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            } else {
                Image(systemName: step.failed ? "xmark.circle.fill" : "checkmark.circle").font(.caption2).foregroundStyle(step.failed ? Color.red : Color.secondary)
            }
            Text(ActivityCopy.label(step.name)).font(.caption)
            Text(step.name).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            if let preview = step.preview { Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if !running, let end = step.finishedAt { Text(ActivityCopy.duration(end.timeIntervalSince(step.startedAt))).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
        }
    }
}
