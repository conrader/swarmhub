import SwiftUI

/// Add/edit sheet for a server routine: name, schedule preset (or raw cron / interval text) and prompt.
struct RoutineEditorSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let bot: Bot
    let job: HermesJob?
    @State private var name: String
    @State private var draft: RoutineScheduleDraft
    @State private var prompt: String
    @State private var saving = false
    @State private var error: String?

    init(bot: Bot, job: HermesJob?) {
        self.bot = bot; self.job = job
        _name = State(initialValue: job?.name ?? "")
        _draft = State(initialValue: job.map { RoutineScheduleDraft(parsing: $0.schedule) } ?? .init())
        _prompt = State(initialValue: job?.prompt ?? "")
    }

    /// Limits from `api_server.py` (`_MAX_NAME_LENGTH`, `_MAX_PROMPT_LENGTH`).
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 && !draft.expression.isEmpty && prompt.count <= 5000
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(job == nil ? "New routine" : "Edit routine").font(.title2.bold())
            TextField("Name", text: $name)
            Picker("Schedule", selection: $draft.preset) { ForEach(RoutinePreset.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            scheduleFields
            Text("\(RoutineScheduleDraft.describe(draft.expression)) · times use the server's time zone").font(.caption).foregroundStyle(.secondary)
            Text("Prompt").font(.headline)
            TextEditor(text: $prompt).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 130)
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(job == nil ? "Create" : "Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!isValid || saving)
            }
        }.padding(22).frame(width: 470).transaction { $0.animation = nil }
    }

    @ViewBuilder private var scheduleFields: some View {
        switch draft.preset {
        case .hourly: Text("At the start of every hour.").font(.caption).foregroundStyle(.secondary)
        case .daily, .weekdays: DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
        case .weekly:
            HStack {
                Picker("Day", selection: $draft.weekday) { ForEach(0..<7, id: \.self) { Text(RoutineScheduleDraft.weekdayNames[$0]).tag($0) } }.frame(maxWidth: 200)
                DatePicker("at", selection: time, displayedComponents: .hourAndMinute)
            }
        case .custom: TextField("Cron (0 9 * * 1) or interval (every 30m)", text: $draft.custom).font(.system(.body, design: .monospaced))
        }
    }

    private var time: Binding<Date> {
        Binding(get: { Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: draft.hour, minute: draft.minute)) ?? .now },
                set: { let parts = Calendar.current.dateComponents([.hour, .minute], from: $0); draft.hour = parts.hour ?? 0; draft.minute = parts.minute ?? 0 })
    }

    private func save() {
        saving = true; error = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), schedule = draft.expression, prompt = prompt
        Task {
            let failure = if let job { await store.updateRoutine(job, for: bot, name: name, schedule: schedule, prompt: prompt) }
                          else { await store.createRoutine(for: bot, name: name, schedule: schedule, prompt: prompt) }
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
