import SwiftUI

struct HerdrRoutineEditor: View {
    private typealias Schedule = HerdrClient.RoutineSchedule

    @Environment(\.dismiss) private var dismiss
    private let existing: HerdrClient.Routine?
    private let displayZone: TimeZone
    private let save: (HerdrClient.RoutineEdit) async throws -> Void

    @State private var name: String
    @State private var task: String
    @State private var frequency: Frequency
    @State private var minutes: String
    @State private var time: Date
    @State private var webhookSource: Schedule.Source?
    @State private var webhookFilters: [FilterDraft]
    @State private var slackFilters: [FilterDraft]
    @State private var reviewWebhook: Bool
    @State private var saving = false
    @State private var error: String?

    private enum Frequency: String, CaseIterable, Identifiable {
        case interval = "Interval", daily = "Daily", weekdays = "Weekdays", webhook = "Webhook"
        var id: Self { self }
    }

    private enum SlackScope: String, CaseIterable {
        case team = "team_id", channel

        var prompt: String {
            switch self {
            case .team: "Workspace ID, e.g. T012AB3CD"
            case .channel: "Channel ID starting with C or G"
            }
        }
    }

    private struct FilterDraft: Identifiable {
        let id = UUID()
        var field = ""
        var equals = ""
        var slackScope: SlackScope?

        var filter: Schedule.Filter {
            .init(field: field.trimmingCharacters(in: .whitespacesAndNewlines), equals: equals)
        }
    }

    init(routine: HerdrClient.Routine?, displayZone: TimeZone, save: @escaping (HerdrClient.RoutineEdit) async throws -> Void) {
        existing = routine
        self.save = save
        _name = State(initialValue: routine?.name ?? "")
        _task = State(initialValue: routine?.task ?? "")
        let initialFrequency: Frequency
        var interval: UInt32 = 60
        var hour = 9
        var minute = 0
        var zone: String?
        var webhookSource: Schedule.Source?
        var filters: [Schedule.Filter] = []
        var review = false
        switch routine?.schedule {
        case .daily(let h, let m, let timezone, let weekdays):
            initialFrequency = weekdays ? .weekdays : .daily
            hour = Int(h)
            minute = Int(m)
            zone = timezone
        case .interval(let minutes):
            initialFrequency = .interval
            interval = minutes
        case .webhook(let source, let savedFilters, let savedReview):
            initialFrequency = .webhook
            webhookSource = source
            filters = savedFilters
            review = savedReview
        case nil:
            initialFrequency = .daily
        }
        self.displayZone = zone.flatMap(TimeZone.init(identifier:)) ?? displayZone
        _frequency = State(initialValue: initialFrequency)
        _minutes = State(initialValue: String(interval))
        _webhookSource = State(initialValue: webhookSource)
        _reviewWebhook = State(initialValue: review)
        let isSlack = webhookSource == .slack
        _webhookFilters = State(initialValue: isSlack ? [] : filters.map { FilterDraft(field: $0.field, equals: $0.equals) })
        // The review queue binds events to the ordered schedule. Preserve the saved filter order.
        var slack = isSlack ? filters.map {
            FilterDraft(field: $0.field, equals: $0.equals, slackScope: SlackScope(rawValue: $0.field))
        } : []
        for scope in SlackScope.allCases where !slack.contains(where: { $0.slackScope == scope }) {
            slack.append(FilterDraft(field: scope.rawValue, slackScope: scope))
        }
        _slackFilters = State(initialValue: slack)
        let calendar = Self.calendar(in: self.displayZone)
        // A fixed reference date keeps today's daylight-saving transition out of the clock picker.
        let components = DateComponents(year: 2001, month: 1, day: 15, hour: hour, minute: minute)
        _time = State(initialValue: calendar.date(from: components) ?? .now)
    }

    private var schedule: Schedule? {
        switch frequency {
        case .interval:
            guard let count = UInt32(minutes.trimmingCharacters(in: .whitespaces)), (1...43_200).contains(count) else { return nil }
            return .interval(minutes: count)
        case .daily, .weekdays:
            let components = Self.calendar(in: displayZone).dateComponents([.hour, .minute], from: time)
            return .daily(hour: UInt8(components.hour ?? 9), minute: UInt8(components.minute ?? 0),
                          timezone: displayZone.identifier, weekdays: frequency == .weekdays)
        case .webhook:
            let filters = webhookSource == .slack ? slackFilters : webhookFilters
            return .webhook(source: webhookSource, filters: filters.map(\.filter), review: reviewWebhook)
        }
    }

    private var nameToSave: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var nameError: String? {
        if nameToSave.unicodeScalars.count > 80 || name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "Enter a routine name up to 80 characters without control characters."
        }
        return nil
    }

    private var taskError: String? {
        if task.utf8.count > 12 * 1024 { return "Instructions can contain up to 12 KiB of text." }
        if task.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) {
            return "Enter instructions as plain text."
        }
        return nil
    }

    private var canSave: Bool {
        guard let schedule, schedule.webhookValidationMessage == nil else { return false }
        return nameError == nil && !nameToSave.isEmpty && taskError == nil
            && task.unicodeScalars.contains { !$0.properties.isWhitespace }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New routine" : "Edit routine").font(.title2.bold())
                .padding(.horizontal, 20).padding(.top, 18).accessibilityAddTraits(.isHeader)
            Form {
                TextField("Name", text: $name)
                if let nameError { validationText(nameError) }
                SettingBlock(title: "Instructions", detail: "What should the bot do each time this routine runs?") {
                    TextEditor(text: $task)
                        .font(.body)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Instructions")
                    if let taskError { validationText(taskError) }
                }
                Section("Schedule") {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(Frequency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch frequency {
                    case .interval:
                        TextField("Minutes between runs", text: $minutes)
                        Text("Between 1 and 43,200 minutes.").font(.caption).foregroundStyle(.secondary)
                    case .daily, .weekdays:
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, displayZone)
                            .environment(\.calendar, Self.calendar(in: displayZone))
                        Text(displayZone.identifier).font(.caption).foregroundStyle(.secondary)
                    case .webhook:
                        webhookFields
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

    @ViewBuilder private var webhookFields: some View {
        Picker("Source", selection: $webhookSource) {
            Text("Generic webhook").tag(nil as Schedule.Source?)
            Text("GitHub").tag(Schedule.Source.github as Schedule.Source?)
            Text("Slack mention").tag(Schedule.Source.slack as Schedule.Source?)
        }
        Toggle("Review before running", isOn: $reviewWebhook)
        if reviewWebhook {
            Text("Incoming events wait for approval before the bot runs.")
                .font(.caption).foregroundStyle(.secondary)
        }
        SettingBlock(title: "JSON field filters", detail: "The event must match every filter.") {
            filterRows(webhookSource == .slack ? $slackFilters : $webhookFilters)
            if let message = schedule?.webhookValidationMessage { validationText(message) }
        }
    }

    private func filterRows(_ filters: Binding<[FilterDraft]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(filters) { $filter in
                if let scope = filter.slackScope {
                    LabeledContent(scope.rawValue) {
                        TextField(scope.rawValue, text: $filter.equals, prompt: Text(scope.prompt))
                            .labelsHidden()
                    }
                    .textFieldStyle(.roundedBorder)
                } else {
                    let id = filter.id
                    HStack(spacing: 6) {
                        TextField("JSON field", text: $filter.field, prompt: Text("e.g. repository.full_name"))
                        TextField("Equals text", text: $filter.equals)
                        Button("Remove filter", systemImage: "minus.circle") {
                            filters.wrappedValue.removeAll { $0.id == id }
                        }
                        .labelStyle(.iconOnly)
                        .help("Remove filter")
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }
            Button("Add filter", systemImage: "plus") { filters.wrappedValue.append(FilterDraft()) }
                .disabled(filters.wrappedValue.count >= Schedule.maximumWebhookFilters)
        }
    }

    private func validationText(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(AppColor.caution)
            .fixedSize(horizontal: false, vertical: true)
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
