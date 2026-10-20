import SwiftUI

/// Settings → Advanced → Heartbeat (P46 4): a template (interval, active hours, prompt) applied to all or chosen Hermes
/// bots in one batch, each bot's own plan, and per bot its next run and last result. Off by default: nothing runs on a
/// box until "Apply" creates the bot's routine. Each box runs at most its advised number of heartbeats at once.
struct SettingsHeartbeatPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var chosen: Set<UUID> = []
    @State private var editing: Bot?

    private var hermesBots: [Bot] { store.bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive } }

    var body: some View {
        let template = Binding(get: { store.heartbeatSettings.template }, set: { store.heartbeatSettings.template = $0; store.save() })
        Section("Template") {
            HeartbeatPlanEditor(plan: template)
            Text(HeartbeatCopy.turns(store.heartbeatSettings.template.wakesPerDay())).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Apply to all") { apply(hermesBots) }.disabled(hermesBots.isEmpty || !store.heartbeatBatch.applying.isEmpty)
                Button("Apply to chosen (\(chosen.count))") { apply(hermesBots.filter { chosen.contains($0.id) }) }
                    .disabled(chosen.isEmpty || !store.heartbeatBatch.applying.isEmpty)
                if !store.heartbeatBatch.applying.isEmpty { ProgressView().controlSize(.small) }
                Spacer()
                if let summary = store.heartbeatBatch.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Off until you apply it. Each bot gets one Hermes routine (\(HeartbeatPlan.jobName)) that answers in its chat; a bot's own heartbeat routine is reused.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.accessibilityIdentifier("heartbeat.template")
        Section("Bots") {
            if hermesBots.isEmpty { Text("No Hermes bots yet: heartbeats run as Hermes routines.").foregroundStyle(.secondary) }
            ForEach(hermesBots) { bot in
                HeartbeatBotRow(bot: bot, chosen: Binding(get: { chosen.contains(bot.id) }, set: { if $0 { chosen.insert(bot.id) } else { chosen.remove(bot.id) } }),
                                edit: { editing = bot })
            }
            ForEach(boxes, id: \.self) { box in
                Text(capacityLine(box)).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityIdentifier("heartbeat.bots")
        .sheet(item: $editing) { bot in HeartbeatOverrideSheet(bot: bot, plan: store.heartbeatSettings.plan(for: bot.id)) }
        .task { await loadRoutines() }
    }

    private var boxes: [String] { Array(Set(hermesBots.map(store.connection(of:)))).sorted() }

    /// "box.example.com: 2 heartbeats at once (advised)", or one while the box was never checked.
    private func capacityLine(_ box: String) -> String {
        let host = URL(string: box)?.host ?? box
        guard store.boxReadings(on: box).capacity != nil else { return "\(host): one heartbeat at a time (capacity not checked yet; Check it under the box's capacity)." }
        let cap = store.heartbeatCap(on: box)
        return "\(host): at most \(cap) \(cap == 1 ? "heartbeat" : "heartbeats") at once (advised from its capacity); the others run a few minutes later."
    }

    private func apply(_ targets: [Bot]) {
        let plan = store.heartbeatSettings.template
        Task { await store.applyHeartbeats(plan, to: targets) }
    }

    private func loadRoutines() async {
        guard store.routines.autoLoad else { return }
        for bot in hermesBots where store.routines.state(for: bot.id).jobs.value == nil { await store.refreshRoutines(for: bot) }
    }
}

/// One bot: chosen for "Apply to chosen", its heartbeat (or Off), its own plan, and what it needs.
struct HeartbeatBotRow: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot; @Binding var chosen: Bool
    let edit: () -> Void
    var body: some View {
        let job = store.heartbeatJob(for: bot)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: $chosen).labelsHidden().toggleStyle(.checkbox)
            BotAvatar(bot: bot, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name).fontWeight(.medium)
                Text(statusLine(job)).font(.caption).foregroundStyle(.secondary)
                if let plan = store.heartbeatSettings.plans[bot.id.uuidString] {
                    Text("\(plan.wakesPerDay(stagger: store.heartbeatStagger(for: bot))) wakes a day · \(plan.prompt == HeartbeatPlan.defaultPrompt ? "default prompt" : "own prompt")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let changed = store.heartbeatBoxChangeNotice(for: bot) {
                    HStack {
                        Text(changed).font(.caption).foregroundStyle(.orange)
                        Button(HeartbeatContextCopy.useBox) { store.useBoxHeartbeatSchedule(bot) }
                        Button(HeartbeatContextCopy.putBack) { Task { store.heartbeatBatch.problems[bot.id] = await store.putBackHeartbeatSchedule(bot) } }
                    }.controlSize(.small).accessibilityIdentifier("heartbeat.changedOnBox")
                }
                if let problem = store.heartbeatBatch.problems[bot.id] { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if store.botChatConflict(bot) != nil {
                    HStack {
                        Text("Another chat of \(store.profile(of: bot)) is titled \"Bot Chat\".").font(.caption).foregroundStyle(.orange)
                        Button("Use this chat") { Task { store.heartbeatBatch.problems[bot.id] = await store.useThisChatAsBotChat(bot) } }.controlSize(.small)
                    }
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if store.heartbeatBatch.applying.contains(bot.id) { ProgressView().controlSize(.small) }
                Button(job == nil ? "Set up…" : "Edit…", action: edit)
                if let job {
                    Button(job.isPaused ? "Resume" : "Pause") { Task { store.heartbeatBatch.problems[bot.id] = await store.setHeartbeat(bot, enabled: job.isPaused) } }
                    Button("Stop") { Task { store.heartbeatBatch.problems[bot.id] = await store.stopHeartbeat(bot) } }
                }
            }.controlSize(.small)
        }.padding(.vertical, 2)
    }

    /// "hourly 08–23 · on · next 14:07 · last ok · silent", or Off.
    private func statusLine(_ job: HermesJob?) -> String {
        guard let summary = store.heartbeatSummary(for: bot) else {
            if case .failed(let reason) = store.routines.state(for: bot.id).jobs { return "Off · routines not read: \(reason)" }
            return "Off"
        }
        return String(summary.dropFirst("Heartbeat · ".count))
    }
}

/// A bot's own plan: starts from its current one (or the template); "Apply" writes its routine.
struct HeartbeatOverrideSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    @State var plan: HeartbeatPlan
    @State private var problem: String?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Heartbeat for \(bot.name)").font(.headline)
            Form { HeartbeatPlanEditor(plan: $plan) }.formStyle(.grouped).frame(height: 260)
            Text(HeartbeatCopy.turns(plan.wakesPerDay(stagger: store.heartbeatStagger(for: bot)))).font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Use the template") { plan = store.heartbeatSettings.template }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to \(bot.name)") {
                    busy = true
                    Task { problem = await store.applyHeartbeat(plan, to: bot); busy = false; if problem == nil { dismiss() } }
                }.keyboardShortcut(.defaultAction).disabled(busy || plan.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 520)
    }
}

/// Interval, active hours and prompt of one plan.
struct HeartbeatPlanEditor: View {
    @Binding var plan: HeartbeatPlan
    var body: some View {
        Picker("Every", selection: $plan.interval) {
            ForEach(HeartbeatPlan.intervals, id: \.self) { Text(ScheduleInterval.label($0).replacingOccurrences(of: "every ", with: "")).tag($0) }
        }
        Toggle("Only between", isOn: Binding(get: { plan.windowStart != nil }, set: { on in
            plan.windowStart = on ? 8 * 60 : nil; plan.windowEnd = on ? 23 * 60 : nil
        }))
        if plan.windowStart != nil {
            HStack {
                hourPicker("From", value: Binding(get: { plan.windowStart ?? 480 }, set: { plan.windowStart = $0 }))
                hourPicker("to", value: Binding(get: { plan.windowEnd ?? 1_380 }, set: { plan.windowEnd = $0 }))
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $plan.prompt).font(.system(size: 12)).frame(minHeight: 54).scrollContentBackground(.hidden)
                .padding(4).background(AppColor.card, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func hourPicker(_ title: String, value: Binding<Int>) -> some View {
        Picker(title, selection: value) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0 * 60) }
            Text("23:59").tag(1_439)
        }
    }
}
