import SwiftUI

private struct ActivityNowKey: EnvironmentKey { static let defaultValue: Date? = nil }

extension EnvironmentValues {
    /// The time the live phase (Thinking, Typing, Working) is read at; nil in the app (the clock, refreshed every
    /// second). Tests fix it, so a slow render on a loaded Mac cannot outlast the Typing pause.
    var activityNow: Date? {
        get { self[ActivityNowKey.self] }
        set { self[ActivityNowKey.self] = newValue }
    }
}

/// P27 D9, P29: what a reply did, one row for the whole turn. While it streams: its Thinking, Typing or Working phase,
/// e.g. "Working… · Running a command · step 3 · 1 m 12 s" (refreshed every second); after it: "12 steps · 4 m 52 s".
/// A chevron opens the steps whenever there is one, streaming or not, and one view for both states keeps the row open
/// when the turn ends.
struct ActivityRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.activityNow) private var fixedNow
    @ObservedObject var message: ChatMessage
    @State private var expanded: Bool
    /// P43: the burst of steps this row shows (nil = every step), whether it carries the live line while the reply streams,
    /// and a header-only live line after the reply's last text.
    let range: Range<Int>?; let live: Bool; let headerOnly: Bool
    init(message: ChatMessage, expanded: Bool = false, range: Range<Int>? = nil, live: Bool = true, headerOnly: Bool = false) {
        self.message = message; _expanded = State(initialValue: expanded); self.range = range; self.live = live; self.headerOnly = headerOnly
    }

    private var streaming: Bool { message.isStreaming && live }
    /// The steps this row lists.
    private var shown: ToolActivity? {
        if headerOnly { return nil }
        guard let range, let activity = message.activity else { return message.activity }
        return activity.burst(range)
    }

    var body: some View {
        if headerOnly ? message.isStreaming : range != nil || ActivityCopy.isRowShown(message.activity, streaming: message.isStreaming) {
            VStack(alignment: .leading, spacing: 6) {
                if streaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in header(now: fixedNow ?? context.date) }
                } else {
                    header(now: fixedNow ?? .now)
                }
                if expanded, let activity = message.activity, let shown, ActivityCopy.canUnfold(shown) {
                    VStack(alignment: .leading, spacing: 4) {
                        if (range?.lowerBound ?? 0) == 0, activity.total > activity.steps.count { Text("Earlier \(activity.total - activity.steps.count) steps not kept").font(.caption2).foregroundStyle(.tertiary) }
                        ForEach(Array(shown.steps.enumerated()), id: \.offset) { _, step in
                            StepLine(step: step, number: activity.number(of: step), running: ActivityCopy.isRunning(step, streaming: message.isStreaming),
                                     thread: step.botMessage.flatMap { store.threadKey(for: $0, in: message) })
                        }
                    }.padding(.leading, 14)
                }
            }
        }
    }

    @ViewBuilder private func header(now: Date) -> some View {
        if ActivityCopy.canUnfold(shown) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).font(.system(size: 9, weight: .semibold))
                    status(now: now)
                }.font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).help(ActivityCopy.toggleHelp(expanded: expanded, total: shown?.total ?? 0, streaming: streaming))
        } else {
            HStack(spacing: 5) { status(now: now) }.font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func status(now: Date) -> some View {
        let activity = message.activity
        if streaming {
            ProgressView().controlSize(.mini)
            Text(ActivityCopy.liveLine(activity, since: message.createdAt, lastText: message.lastTextAt, now: now)).monospacedDigit()
            if ChatActivityPhase.current(activity, lastText: message.lastTextAt, now: now) == .working,
               let preview = activity?.current?.preview {
                Text(preview).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        } else if let shown, let summary = ActivityCopy.summary(shown, since: range == nil ? message.createdAt : shown.steps.first?.startedAt ?? message.createdAt) {
            Text(summary).monospacedDigit()
            if shown.steps.contains(where: \.failed) { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        }
    }
}

private struct StepLine: View {
    let step: ToolStep; let number: Int; let running: Bool
    /// P34 D4: the thread a bot-msg step wrote to.
    var thread: BotThreadKey? = nil
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
            if let thread { BotMessageChip(key: thread) }
            if let preview = step.preview, thread == nil { Text(preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if !running, let end = step.finishedAt { Text(ActivityCopy.duration(end.timeIntervalSince(step.startedAt))).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
        }
    }
}
