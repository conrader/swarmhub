import SwiftUI

/// Add/edit sheet for a server routine (P21b item 2): name, a plain schedule picker (every day, weekdays, every week,
/// every few hours) and what the agent should do. The raw schedule text sits under Advanced (`RoutineScheduleAdvanced`)
/// and round-trips: a schedule the picker cannot show opens there, unfolded, exactly as stored.
struct RoutineEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    let job: HermesJob?
    @State private var name: String
    @State private var schedule: RoutineScheduleEditor
    @State private var prompt: String
    @State private var saving = false
    @State private var error: String?

    /// `schedule`, `name` and `prompt` prefill a new routine (recs1: a suggestion the bot did not make itself).
    init(bot: Bot, job: HermesJob?, schedule: String? = nil, name: String = "", prompt: String = "") {
        self.bot = bot; self.job = job
        _name = State(initialValue: job?.name ?? name)
        _schedule = State(initialValue: RoutineScheduleEditor(schedule: job?.schedule ?? schedule))
        _prompt = State(initialValue: job?.prompt ?? prompt)
    }

    /// Limits from `api_server.py` (`_MAX_NAME_LENGTH`, `_MAX_PROMPT_LENGTH`).
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 && !schedule.expression.isEmpty && prompt.count <= 5000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job == nil ? InspectorCopy.newRoutine : InspectorCopy.editRoutine).font(.title2.bold())
            TextField(InspectorCopy.routineName, text: $name)
            Picker(InspectorCopy.schedule, selection: pick(\.preset)) {
                ForEach(RoutinePreset.pickable) { Text(title($0)).tag($0) }
                if schedule.draft.preset == .custom { Text(InspectorCopy.customSchedule).tag(RoutinePreset.custom) }
            }.pickerStyle(.menu).fixedSize()
            scheduleFields
            Text(summary).font(.caption).foregroundStyle(.secondary)
            AdvancedFold(startsOpen: schedule.opensAdvanced) { RoutineScheduleAdvanced(text: Binding(get: { schedule.raw }, set: { schedule.setRaw($0) })) }
            Text(InspectorCopy.routinePrompt).font(.headline)
            TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 130)
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button(InspectorCopy.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(job == nil ? InspectorCopy.create : InspectorCopy.save) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!isValid || saving)
            }
        }.padding(22).frame(width: 470).transaction { $0.animation = nil }
    }

    private func title(_ preset: RoutinePreset) -> String {
        switch preset {
        case .daily: InspectorCopy.everyDay
        case .weekdays: InspectorCopy.weekdays
        case .weekly: InspectorCopy.everyWeek
        case .everyHours: InspectorCopy.everyFewHours
        case .custom: InspectorCopy.customSchedule
        }
    }

    private var summary: String {
        schedule.draft.preset == .custom ? InspectorCopy.customSummary : InspectorCopy.scheduleSummary(RoutineScheduleDraft.describe(schedule.expression))
    }

    @ViewBuilder private var scheduleFields: some View {
        switch schedule.draft.preset {
        case .daily, .weekdays: DatePicker(InspectorCopy.at, selection: time, displayedComponents: .hourAndMinute).fixedSize()
        case .weekly:
            HStack {
                Picker(InspectorCopy.on, selection: pick(\.weekday)) { ForEach(0..<7, id: \.self) { Text(RoutineScheduleDraft.weekdayNames[$0]).tag($0) } }.frame(maxWidth: 200)
                DatePicker(InspectorCopy.at, selection: time, displayedComponents: .hourAndMinute).fixedSize()
            }
        case .everyHours:
            Picker(InspectorCopy.every, selection: pick(\.everyHours)) {
                ForEach(RoutineScheduleDraft.hourSteps, id: \.self) { Text(InspectorCopy.hours($0)).tag($0) }
            }.frame(maxWidth: 200)
        case .custom: EmptyView()
        }
    }

    /// A picker binding that writes through `RoutineScheduleEditor.pick`, so the raw text follows.
    private func pick<Value>(_ path: WritableKeyPath<RoutineScheduleDraft, Value>) -> Binding<Value> {
        Binding(get: { schedule.draft[keyPath: path] }, set: { value in schedule.pick { $0[keyPath: path] = value } })
    }

    private var time: Binding<Date> {
        Binding(get: { RoutineScheduleDraft.pickerDate(hour: schedule.draft.hour, minute: schedule.draft.minute) },
                set: { date in let time = RoutineScheduleDraft.pickerTime(date); schedule.pick { $0.hour = time.hour; $0.minute = time.minute } })
    }

    private func save() {
        saving = true; error = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), schedule = schedule.expression, prompt = prompt
        Task {
            let failure = if let job { await store.updateRoutine(job, for: bot, name: name, schedule: schedule, prompt: prompt) }
                          else { await store.createRoutine(for: bot, name: name, schedule: schedule, prompt: prompt) }
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
