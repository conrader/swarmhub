import SwiftUI

/// Routines tab: the bot's Hermes cron jobs, plus routines that are not on the server yet.
struct RoutinesView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @ObservedObject var cache: RoutinesCache
    @State private var editor: RoutineEditorTarget?
    @State private var confirmingDelete: String?

    var body: some View {
        let state = cache.state(for: bot.id)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Routines").font(.headline); Spacer()
                if bot.backend == .hermes {
                    Button { Task { await store.refreshRoutines(for: bot) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(state.isRefreshing).help("Refresh")
                    Button { editor = .new } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).disabled(state.jobs.value == nil).help("New routine")
                }
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if bot.backend == .openClaw {
                Text(OpenClawOverview.routines).font(.caption).foregroundStyle(.secondary)
            } else if bot.backend != .hermes {
                Text("Routines run on a Hermes server. This bot's routines are shown read-only.").font(.caption).foregroundStyle(.secondary)
            } else {
                switch state.jobs {
                case .loading: ProgressView().controlSize(.small)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await store.refreshRoutines(for: bot) } }.controlSize(.small)
                case .unavailable(let reason): Text(reason).font(.caption).foregroundStyle(.secondary)
                case .loaded(let jobs):
                    ForEach(jobs) { job in
                        RoutineJobRow(job: job, busy: state.busy.contains(job.id), confirmingDelete: $confirmingDelete,
                                      toggle: { enabled in Task { await store.setRoutine(job, enabled: enabled, for: bot) } },
                                      run: { Task { await store.runRoutineNow(job, for: bot) } },
                                      edit: { editor = .edit(job) },
                                      delete: { confirmingDelete = nil; Task { await store.deleteRoutine(job, for: bot) } })
                    }
                    if jobs.isEmpty && bot.routines.isEmpty { Text("No routines yet. Create one to run this bot on a schedule.").foregroundStyle(.secondary) }
                }
            }
            ForEach(bot.routines) { routine in
                PendingRoutineRow(routine: routine, canCreate: state.jobs.value != nil, busy: state.busy.contains(routine.id.uuidString)) {
                    Task { await store.createRoutineOnServer(routine, for: bot) }
                }
            }
            if bot.backend != .hermes && bot.routines.isEmpty { Text("No routines yet.").foregroundStyle(.secondary) }
        }
        .transaction { $0.animation = nil }
        .sheet(item: $editor) { target in RoutineEditorSheet(bot: bot, job: target.job) }
        .task(id: bot.id) { if cache.autoLoad, bot.backend == .hermes { await store.refreshRoutines(for: bot) } }
    }
}

enum RoutineEditorTarget: Identifiable {
    case new, edit(HermesJob)
    var id: String { if case .edit(let job) = self { job.id } else { "new" } }
    var job: HermesJob? { if case .edit(let job) = self { job } else { nil } }
}

private struct RoutineJobRow: View {
    let job: HermesJob; let busy: Bool
    @Binding var confirmingDelete: String?
    let toggle: @MainActor @Sendable (Bool) -> Void
    let run: () -> Void, edit: () -> Void, delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.name).fontWeight(.medium).lineLimit(1); Spacer()
                Toggle("", isOn: Binding(get: { !job.isPaused }, set: toggle)).labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(busy)
                    .help(job.isPaused ? "Paused — turn on to resume" : "On — turn off to pause")
            }
            Text(RoutineScheduleDraft.describe(job.schedule)).font(.caption).foregroundStyle(.secondary)
            Text(timing).font(.caption2).foregroundStyle(.tertiary)
            if let error = job.lastError { Text(error).font(.caption2).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
            HStack(spacing: 12) {
                if confirmingDelete == job.id {
                    Text("Delete this routine?").foregroundStyle(.secondary); Spacer()
                    Button("Cancel") { confirmingDelete = nil }
                    Button("Delete") { delete() }.foregroundStyle(.red)
                } else {
                    Button("Run now", action: run); Button("Edit", action: edit); Spacer()
                    if busy { ProgressView().controlSize(.mini) }
                    Button("Delete") { confirmingDelete = job.id }.foregroundStyle(.secondary)
                }
            }.font(.caption).buttonStyle(.plain).disabled(busy)
        }.padding(10).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private var timing: String {
        var parts = [job.state.capitalized]
        if let last = RoutineTime.relative(job.lastRunAt) { parts.append("Last run \(last)" + (job.lastStatus.map { " · \($0)" } ?? "")) } else { parts.append("Never run") }
        if !job.isPaused, let next = RoutineTime.relative(job.nextRunAt) { parts.append("Next \(next)") }
        return parts.joined(separator: " · ")
    }
}

/// A routine stored only in the app (imported, or made before routines lived on the server).
private struct PendingRoutineRow: View {
    let routine: BotRoutine; let canCreate: Bool; let busy: Bool; let create: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(routine.name).fontWeight(.medium).lineLimit(1)
            Text(RoutineScheduleDraft.describe(routine.schedule)).font(.caption).foregroundStyle(.secondary)
            Text(routine.importKind == .cron ? "Imported — not on server" : "Local — not on server").font(.caption2).foregroundStyle(.tertiary)
            if canCreate {
                HStack {
                    Button("Create on server", action: create).font(.caption).buttonStyle(.plain).disabled(busy)
                        .help("Creates this routine on the bot's Hermes server, paused")
                    if busy { ProgressView().controlSize(.mini) }
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}

/// "Routine finished" card posted into the bot's chat by the routine inbox.
struct RoutineResultCard: View {
    let message: ChatMessage
    var body: some View {
        let status = message.metadata["status"] ?? "ok"
        let failed = status != "ok" || message.metadata["error"] != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "clock.badge.checkmark").foregroundStyle(failed ? Color.red : Color.accentColor)
                Text("Routine finished").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(); Text(status.capitalized).font(.caption2).foregroundStyle(failed ? Color.red : Color.secondary)
            }
            Text(message.metadata["routine"] ?? "Routine").font(.callout.weight(.semibold))
            if !message.content.isEmpty { Text(message.content).font(.callout).textSelection(.enabled).lineSpacing(2) }
            if let error = message.metadata["error"] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let note = message.metadata["note"] { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }.padding(12).frame(maxWidth: 500, alignment: .leading).background(AppColor.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(AppColor.separator, lineWidth: 0.5))
    }
}
