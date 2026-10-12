import SwiftUI

struct BotEditorView: View {
    @Environment(\.dismiss) private var dismiss; @EnvironmentObject private var store: AppStore; let bot: Bot?
    @State private var name = ""; @State private var title = "Personal agent"; @State private var details = ""; @State private var persona = "You are a thoughtful, capable assistant."; @State private var backend = BackendKind.mock; @State private var avatarName = BotAvatarName.faceCoral
    @State private var hidden = false; @State private var notifications = true
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(bot == nil ? "New agent" : "Agent settings").font(.title2.bold()); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).font(.title3) }.buttonStyle(.plain) }.padding(20)
            Divider(); Form {
                Picker("Avatar", selection: $avatarName) { Section("Flat bot faces") { ForEach(BotAvatarName.allCases.filter(\.isFlatFace)) { avatar in HStack { AvatarImage(name: avatar).scaledToFill().frame(width: 24, height: 24).clipShape(Circle()); Text(avatar.displayName) }.tag(avatar) } }; Section("Clay collection") { ForEach(BotAvatarName.allCases.filter { !$0.isFlatFace }) { avatar in HStack { AvatarImage(name: avatar).scaledToFill().frame(width: 24, height: 24).clipShape(Circle()); Text(avatar.displayName) }.tag(avatar) } } }
                TextField("Name", text: $name); TextField("Title", text: $title); TextField("Description", text: $details, axis: .vertical).lineLimit(2...4)
                Picker("Backend", selection: $backend) { ForEach(BackendKind.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("Show in sidebar", isOn: Binding(get: { !hidden }, set: { hidden = !$0 })); Toggle("Notifications", isOn: $notifications)
                Section("Instructions") { TextEditor(text: $persona).frame(height: 90) }
            }.formStyle(.grouped).padding(.horizontal, 8)
            Divider(); HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }.padding(16)
        }.frame(width: 500, height: 600).background(AppColor.panel).onAppear { if let bot { name = bot.name; title = bot.title; details = bot.botDescription; persona = bot.persona; backend = bot.backend; avatarName = bot.avatarName; hidden = bot.isHidden; notifications = bot.notificationsEnabled } }
    }
    private func save() { if let bot { bot.name = name; bot.title = title; bot.botDescription = details; bot.persona = persona; bot.backend = backend; bot.avatarName = avatarName; bot.isHidden = hidden; bot.notificationsEnabled = notifications; store.save() } else { store.addBot(name: name, persona: persona, backend: backend, avatarName: avatarName) }; dismiss() }
}
