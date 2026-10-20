import SwiftUI
import SwarmHubCore
import UniformTypeIdentifiers

/// A catalogue v1 form on iOS (P7c). Values live in the shared `SDUIInteraction`; submit goes through
/// `SDUIActionRouter.submit`, which maps only to the existing routine create and save paths, exactly as on the Mac.
struct SDUIFormView: View {
    let form: SDUIRenderForm
    let context: SDUINodeContext

    var body: some View {
        let problems = context.problems(form)
        VStack(alignment: .leading, spacing: 12) {
            if let title = form.title { Text(verbatim: title).font(.headline) }
            ForEach(form.fields, id: \.id) { field in
                SDUIFieldView(field: field, value: binding(field.id))
                if problems[field.id] == "too_long", let limit = field.maxLength {
                    Text(verbatim: "At most \(limit) characters.").font(.footnote).foregroundStyle(.red)
                }
            }
            HStack {
                if context.busy { ProgressView() }
                Spacer()
                Button { context.submit(form) } label: { Text(verbatim: form.submitLabel) }
                    .buttonStyle(.borderedProminent)
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
    @State private var picking = false

    private var text: Binding<String> { Binding(get: { value.text }, set: { value = .text($0) }) }
    private var flag: Binding<Bool> {
        Binding(get: { if case .flag(let on) = value { on } else { false } }, set: { value = .flag($0) })
    }
    private var label: Text { Text(verbatim: field.label + (field.required ? " *" : "")) }

    var body: some View {
        switch field.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                label.font(.subheadline.weight(.semibold))
                TextField(text: text, prompt: field.placeholder.map { Text(verbatim: $0) }) { label }
                    .textFieldStyle(.roundedBorder)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 4) {
                label.font(.subheadline.weight(.semibold))
                TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(6).frame(minHeight: 120)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        case .choice:
            Picker(selection: text) {
                Text(verbatim: "—").tag("")
                ForEach(field.options, id: \.value) { Text(verbatim: $0.label).tag($0.value) }
            } label: { label }.pickerStyle(.menu)
        case .toggle:
            Toggle(isOn: flag) { label }
        case .date:
            DatePicker(selection: date, displayedComponents: [.date, .hourAndMinute]) { label }
        case .schedule:
            // iOS has no compiled schedule picker yet: the form value is the schedule expression, as typed.
            VStack(alignment: .leading, spacing: 4) {
                label.font(.subheadline.weight(.semibold))
                TextField(text: text, prompt: field.placeholder.map { Text(verbatim: $0) }) { label }
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        case .filePick:
            HStack {
                label
                Button { picking = true } label: { Text(verbatim: "Choose…") }
                if !value.text.isEmpty { Text(verbatim: value.text).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: types) { result in
                // Only the chosen file's name is kept; the file is never read (no declared action consumes it).
                if case .success(let url) = result { value = .text(url.lastPathComponent) }
            }
        }
    }

    private var types: [UTType] {
        let types = field.types.compactMap { UTType($0) }
        return types.isEmpty ? [.item] : types
    }

    /// ISO 8601 text in the form state; an empty or unreadable value shows now.
    private var date: Binding<Date> {
        Binding(get: { (try? Date(value.text, strategy: .iso8601)) ?? .now },
                set: { value = .text($0.formatted(.iso8601)) })
    }
}
