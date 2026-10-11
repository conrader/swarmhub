import SwiftUI

struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    let bot: Bot?
    @State private var name = ""
    @State private var persona = "You are a thoughtful, capable assistant."
    @State private var backend = BackendKind.mock

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(bot == nil ? "New Bot" : "Edit Bot").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                Picker("Backend", selection: $backend) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
                TextEditor(text: $persona).frame(height: 120)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(20).frame(width: 440).onAppear { if let bot { name = bot.name; persona = bot.persona; backend = bot.backend } }
    }
    private func save() {
        if let bot { bot.name = name; bot.persona = persona; bot.backend = backend; store.save() }
        else { store.addBot(name: name, persona: persona, backend: backend) }
        dismiss()
    }
}
