import SwiftUI

struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var name = ""; @State private var title = "Personal agent"; @State private var details = ""; @State private var persona = "You are a thoughtful, capable assistant."; @State private var backend = BackendKind.mock; @State private var avatarName = BotAvatarName.robot
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? "New agent" : "Agent settings").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Picker("Avatar", selection: $avatarName) { ForEach(BotAvatarName.allCases) { avatar in HStack { AvatarImage(name: avatar).scaledToFill().frame(width: 24, height: 24).clipShape(Circle()); Text(avatar.rawValue.capitalized) }.tag(avatar) } }
                TextField("Name", text: $name); TextField("Title", text: $title); TextField("Description", text: $details, axis: .vertical).lineLimit(2...4)
                Picker("Backend", selection: $backend) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
                Section("Instructions") { TextEditor(text: $persona).frame(height: 90) }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 500, height: 560).onAppear { if let bot { name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend; avatarName = bot.avatarName } }
    }
    private func save() { if let bot { bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona; bot.backend = backend; bot.avatarName = avatarName; store.save() } else { store.addBot(name: name, persona: persona, backend: backend, avatarName: avatarName) }; dismiss() }
}
