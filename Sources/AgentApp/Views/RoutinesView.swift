import SwiftUI

/// Routines tab: the bot's Hermes cron jobs, plus routines that are not on the server yet, then its webhooks.
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
                Text("Routines run on a Hermes server. This agent's routines are shown read-only.").font(.caption).foregroundStyle(.secondary)
            } else {
                switch state.jobs {
                case .loading: ProgressView().controlSize(.small)
                case .failed(let reason):
                    Text(reason).font(.caption).foregroundStyle(.red)
                    Button("Retry") { Task { await store.refreshRoutines(for: bot) } }.controlSize(.small)
                case .unavailable(let reason): Text(reason).font(.caption).foregroundStyle(.secondary)
                case .loaded(let jobs):
                    ForEach(jobs) { job in
                        RoutineJobRow(job: job, busy: state.busy.contains(job.id), running: RoutineWatch.isRunning(job, in: state),
                                      silent: AppStore.sameRoutineRun(state.silentRuns[job.id], job.lastRunAt), confirmingDelete: $confirmingDelete,
                                      toggle: { enabled in Task { await store.setRoutine(job, enabled: enabled, for: bot) } },
                                      run: { Task { await store.runRoutineNow(job, for: bot) } },
                                      edit: { editor = .edit(job) },
                                      delete: { confirmingDelete = nil; Task { await store.deleteRoutine(job, for: bot) } })
                    }
                    if jobs.isEmpty && bot.routines.isEmpty { Text("No routines yet. Create one to run this agent on a schedule.").foregroundStyle(.secondary) }
                }
            }
            ForEach(bot.routines) { routine in
                PendingRoutineRow(routine: routine, canCreate: state.jobs.value != nil, busy: state.busy.contains(routine.id.uuidString),
                                  create: { Task { await store.createRoutineOnServer(routine, for: bot) } },
                                  remove: { store.removePendingRoutine(routine, from: bot) })
            }
            if bot.backend != .hermes && bot.routines.isEmpty { Text("No routines yet.").foregroundStyle(.secondary) }
            if store.canManageWebhooks(bot) { Divider().padding(.vertical, 4); WebhooksSection(bot: bot, cache: store.webhooks) }
        }
        .transaction { $0.animation = nil }
        .sheet(item: $editor) { target in RoutineEditorHost(bot: bot, job: target.job) }
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
    /// P43: Running… from the click until the run is seen; Run now is off meanwhile.
    var running = false
    /// P44: the last run answered `[SILENT]`, so it posted no card.
    var silent = false
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
                    if running {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Running…") }.foregroundStyle(.secondary).help("The result appears in this agent's chat when the run ends")
                    } else { Button("Run now", action: run) }
                    Button("Edit", action: edit); Spacer()
                    if busy { ProgressView().controlSize(.mini) }
                    Button("Delete") { confirmingDelete = job.id }.foregroundStyle(.secondary)
                }
            }.font(.caption).buttonStyle(.plain).disabled(busy)
        }.padding(10).background(AppColor.raised, in: RoundedRectangle(cornerRadius: 9))
    }

    private var timing: String { RoutineRowCopy.timing(job, running: running, silent: silent) }
}

enum RoutineRowCopy {
    /// "Active · Last run 5 min ago · ok · silent · Next in 55 min".
    static func timing(_ job: HermesJob, running: Bool, silent: Bool) -> String {
        var parts = [running ? "Running…" : job.state.capitalized]
        if let last = RoutineTime.relative(job.lastRunAt) { parts.append("Last run \(last)" + (job.lastStatus.map { " · \($0)" } ?? "") + (silent ? " · silent" : "")) } else { parts.append("Never run") }
        if !job.isPaused, let next = RoutineTime.relative(job.nextRunAt) { parts.append("Next \(next)") }
        return parts.joined(separator: " · ")
    }
}

/// A routine stored only in the app (imported, or made before routines lived on the server). An imported one without a
/// schedule (a Grok Bot routine: Grok keeps none) needs setup: it can only be removed, or recreated with +.
private struct PendingRoutineRow: View {
    let routine: BotRoutine; let canCreate: Bool; let busy: Bool; let create: () -> Void; let remove: () -> Void
    var needsSetup: Bool { routine.schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(routine.name).fontWeight(.medium).lineLimit(1)
            if needsSetup {
                Text("Paused · needs setup: no schedule or prompt was imported. Use + to create it with one.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(RoutineScheduleDraft.describe(routine.schedule)).font(.caption).foregroundStyle(.secondary)
            }
            Text(routine.importKind == .cron ? "Imported — not on server" : "Local — not on server").font(.caption2).foregroundStyle(.tertiary)
            HStack {
                if canCreate, !needsSetup {
                    Button("Create on server", action: create).font(.caption).buttonStyle(.plain).disabled(busy)
                        .help("Creates this routine on the agent's Hermes server, paused")
                }
                Button("Remove", action: remove).font(.caption).buttonStyle(.plain).disabled(busy)
                    .help("Removes this routine from \(AppConstants.name); nothing on the server changes")
                if busy { ProgressView().controlSize(.mini) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(AppColor.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }
}
