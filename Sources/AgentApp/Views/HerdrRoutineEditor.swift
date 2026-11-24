import SwiftUI

struct HerdrRoutineEditor: View {
    private typealias Schedule = HerdrClient.RoutineSchedule

    @Environment(\.dismiss) private var dismiss
    private let existing: HerdrClient.Routine?
    private let displayZone: TimeZone
    private let save: (HerdrClient.RoutineEdit) async throws -> Void
    private let pinnedZone: String?

    @State private var name: String
    @State private var task: String
    @State private var frequency: Frequency
    @State private var minutes: String
    @State private var time: Date
    @State private var saving = false
    @State private var error: String?

    private enum Frequency: String, CaseIterable, Identifiable {
        case interval = "Interval", daily = "Daily", weekdays = "Weekdays", webhook = "Webhook"
        var id: Self { self }
    }

    init(routine: HerdrClient.Routine?, displayZone: TimeZone, save: @escaping (HerdrClient.RoutineEdit) async throws -> Void) {
        existing = routine
        self.displayZone = displayZone
        self.save = save
        _name = State(initialValue: routine?.name ?? "")
        _task = State(initialValue: routine?.task ?? "")
        let initialFrequency: Frequency
        var interval: UInt32 = 60
        var hour = 9
        var minute = 0
        var zone: String?
        switch routine?.schedule {
        case .daily(let h, let m, let timezone, let weekdays):
            initialFrequency = weekdays ? .weekdays : .daily
            hour = Int(h)
            minute = Int(m)
            zone = timezone
        case .interval(let minutes):
            initialFrequency = .interval
            interval = minutes
        case .webhook:
            initialFrequency = .webhook
        case nil:
            initialFrequency = .daily
        }
        pinnedZone = zone
        _frequency = State(initialValue: initialFrequency)
        _minutes = State(initialValue: String(interval))
        let calendar = Self.calendar(in: zone.flatMap(TimeZone.init(identifier:)) ?? displayZone)
        // A fixed reference date keeps today's daylight-saving transition out of the clock picker.
        let components = DateComponents(year: 2001, month: 1, day: 15, hour: hour, minute: minute)
        _time = State(initialValue: calendar.date(from: components) ?? .now)
    }

    private var scheduleZone: TimeZone { pinnedZone.flatMap(TimeZone.init(identifier:)) ?? displayZone }

    private var frequencies: [Frequency] {
        if case .webhook = existing?.schedule { return Frequency.allCases }
        return [.interval, .daily, .weekdays]
    }

    private var schedule: Schedule? {
        switch frequency {
        case .interval:
            guard let count = UInt32(minutes.trimmingCharacters(in: .whitespaces)), (1...43_200).contains(count) else { return nil }
            return .interval(minutes: count)
        case .daily, .weekdays:
            let components = Self.calendar(in: scheduleZone).dateComponents([.hour, .minute], from: time)
            return .daily(hour: UInt8(components.hour ?? 9), minute: UInt8(components.minute ?? 0),
                          timezone: pinnedZone, weekdays: frequency == .weekdays)
        case .webhook:
            return existing?.schedule
        }
    }

    private var nameToSave: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !nameToSave.isEmpty && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && schedule != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New routine" : "Edit routine").font(.title2.bold())
                .padding(.horizontal, 20).padding(.top, 18).accessibilityAddTraits(.isHeader)
            Form {
                TextField("Name", text: $name)
                SettingBlock(title: "Instructions", detail: "What should the bot do each time this routine runs?") {
                    TextEditor(text: $task)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Instructions")
                }
                Section("Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(frequencies) { Text($0.rawValue).tag($0) }
                    }
                    switch frequency {
                    case .interval:
                        TextField("Minutes between runs", text: $minutes)
                        Text("Between 1 and 43,200 minutes.").font(.caption).foregroundStyle(.secondary)
                    case .daily, .weekdays:
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, scheduleZone)
                            .environment(\.calendar, Self.calendar(in: scheduleZone))
                        Text(pinnedZone ?? "Follows the workspace time zone").font(.caption).foregroundStyle(.secondary)
                    case .webhook:
                        Text(existing?.schedule.summary(in: displayZone) ?? "Webhook")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if let error { StatusCard(kind: .warning, title: "Couldn’t save routine", detail: error) {} }
            }
            .formStyle(.grouped)
            .disabled(saving)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(existing == nil ? "Create Routine" : "Save") { submit() }
                    .keyboardShortcut(.defaultAction).disabled(saving || !canSave)
            }
            .padding(16)
        }
        .frame(width: 450, height: 450)
        .interactiveDismissDisabled(saving)
    }

    private func submit() {
        guard canSave, let schedule, !saving else { return }
        saving = true
        error = nil
        let edit = HerdrClient.RoutineEdit(name: nameToSave, task: task, schedule: schedule)
        Task {
            defer { saving = false }
            do {
                try await save(edit)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
}
