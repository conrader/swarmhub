import AppKit
import SwiftUI
import SwarmHubCore
import UniformTypeIdentifiers

/// A catalogue v1 form (P7b). Values live in `SDUIDocumentView`; submit goes through `SDUIActionRouter.submit`, which
/// maps only to the existing routine create and save paths.
struct SDUIFormView: View {
    let form: SDUIRenderForm
    let context: SDUINodeContext

    var body: some View {
        let problems = context.problems(form)
        VStack(alignment: .leading, spacing: 10) {
            if let title = form.title { Text(verbatim: title).font(.headline) }
            ForEach(form.fields, id: \.id) { field in
                SDUIFieldView(field: field, value: binding(field.id))
                if problems[field.id] == "too_long", let limit = field.maxLength {
                    Text(verbatim: "At most \(limit) characters.").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                if context.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button { context.submit(form) } label: { Text(verbatim: form.submitLabel) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty || context.busy || !context.isAvailable(form.submit, nil))
            }
        }
    }

    private func binding(_ field: String) -> Binding<SDUIFieldValue> {
        Binding(get: { context.value(form, field) }, set: { context.setValue(form, field, $0) })
    }
}

struct SDUIFieldView: View {
    let field: SDUIRenderField
    @Binding var value: SDUIFieldValue

    private var text: Binding<String> { Binding(get: { value.text }, set: { value = .text($0) }) }
    private var flag: Binding<Bool> {
        Binding(get: { if case .flag(let on) = value { on } else { false } }, set: { value = .flag($0) })
    }
    private var label: Text { Text(verbatim: field.label + (field.required ? " *" : "")) }

    var body: some View {
        switch field.kind {
        case .text:
            TextField(text: text, prompt: field.placeholder.map { Text(verbatim: $0) }) { label }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                label.font(.headline)
                TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 110)
                    .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        case .choice:
            Picker(selection: text) {
                Text(verbatim: "—").tag("")
                ForEach(field.options, id: \.value) { Text(verbatim: $0.label).tag($0.value) }
            } label: { label }.pickerStyle(.menu).fixedSize()
        case .toggle:
            Toggle(isOn: flag) { label }
        case .date:
            DatePicker(selection: date, displayedComponents: [.date, .hourAndMinute]) { label }.fixedSize()
        case .schedule:
            SDUIScheduleField(label: label, text: text)
        case .filePick:
            HStack {
                label
                Button { pick() } label: { Text(verbatim: "Choose…") }.controlSize(.small)
                if !value.text.isEmpty { Text(verbatim: value.text).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }

    /// ISO 8601 text in the form state; an empty or unreadable value shows now.
    private var date: Binding<Date> {
        Binding(get: { (try? Date(value.text, strategy: .iso8601)) ?? .now },
                set: { value = .text($0.formatted(.iso8601)) })
    }

    /// Only the chosen file's name is kept; the file is never read (no declared action consumes it).
    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = field.types.compactMap { UTType($0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        if panel.runModal() == .OK, let url = panel.url { value = .text(url.lastPathComponent) }
    }
}

/// The `schedule` field: the routine editor's picker (`RoutineScheduleEditor`) and its raw text under Advanced. The
/// form value is the expression the compiled editor would save.
struct SDUIScheduleField: View {
    let label: Text
    @Binding var text: String
    @State private var editor: RoutineScheduleEditor

    init(label: Text, text: Binding<String>) {
        self.label = label
        _text = text
        let stored = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        _editor = State(initialValue: RoutineScheduleEditor(schedule: stored.isEmpty ? nil : text.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: pick(\.preset)) {
                ForEach(RoutinePreset.pickable) { Text(verbatim: Self.title($0)).tag($0) }
                if editor.draft.preset == .custom { Text(verbatim: InspectorCopy.customSchedule).tag(RoutinePreset.custom) }
            } label: { label }.pickerStyle(.menu).fixedSize()
            switch editor.draft.preset {
            case .daily, .weekdays: DatePicker(InspectorCopy.at, selection: time, displayedComponents: .hourAndMinute).fixedSize()
            case .weekly:
                HStack {
                    Picker(InspectorCopy.on, selection: pick(\.weekday)) {
                        ForEach(0..<7, id: \.self) { Text(verbatim: RoutineScheduleDraft.weekdayNames[$0]).tag($0) }
                    }.frame(maxWidth: 200)
                    DatePicker(InspectorCopy.at, selection: time, displayedComponents: .hourAndMinute).fixedSize()
                }
            case .everyHours:
                Picker(InspectorCopy.every, selection: pick(\.everyHours)) {
                    ForEach(RoutineScheduleDraft.hourSteps, id: \.self) { Text(verbatim: InspectorCopy.hours($0)).tag($0) }
                }.frame(maxWidth: 200)
            case .custom: EmptyView()
            }
            AdvancedFold(startsOpen: editor.opensAdvanced) {
                RoutineScheduleAdvanced(text: Binding(get: { editor.raw }, set: { editor.setRaw($0) }))
            }
        }
        .onAppear { if text != editor.expression { text = editor.expression } }
        .onChange(of: editor) { text = editor.expression }
    }

    static func title(_ preset: RoutinePreset) -> String {
        switch preset {
        case .daily: InspectorCopy.everyDay
        case .weekdays: InspectorCopy.weekdays
        case .weekly: InspectorCopy.everyWeek
        case .everyHours: InspectorCopy.everyFewHours
        case .custom: InspectorCopy.customSchedule
        }
    }

    private func pick<Value>(_ path: WritableKeyPath<RoutineScheduleDraft, Value>) -> Binding<Value> {
        Binding(get: { editor.draft[keyPath: path] }, set: { value in editor.pick { $0[keyPath: path] = value } })
    }

    private var time: Binding<Date> {
        Binding(get: { RoutineScheduleDraft.pickerDate(hour: editor.draft.hour, minute: editor.draft.minute) },
                set: { date in let time = RoutineScheduleDraft.pickerTime(date); editor.pick { $0.hour = time.hour; $0.minute = time.minute } })
    }
}
