import SwiftUI

struct SidebarView: View {
    let bots: [Bot]
    @Binding var selection: Bot?
    @State private var editorBot: Bot?
    @State private var showingNew = false
    var body: some View {
        List(selection: $selection) {
            Section("Bots") {
                ForEach(bots) { bot in
                    HStack(spacing: 10) {
                        Text(bot.initial).font(.headline).frame(width: 30, height: 30).background(Color.accentColor.gradient, in: Circle()).foregroundStyle(.white)
                        Text(bot.name).lineLimit(1)
                        Spacer()
                        if bot.unreadCount > 0 { Text("\(bot.unreadCount)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2).background(Color.accentColor, in: Capsule()).foregroundStyle(.white) }
                    }.tag(bot).contextMenu { Button("Edit…") { editorBot = bot } }
                }
            }
        }.listStyle(.sidebar).navigationTitle(AppConstants.name)
            .safeAreaInset(edge: .bottom) { HStack { Button { showingNew = true } label: { Label("New Bot", systemImage: "plus") }; Spacer(); SettingsLink { Image(systemName: "gear") } }.padding(10).background(.bar) }
            .sheet(isPresented: $showingNew) { BotEditorView(bot: nil) }
            .sheet(item: $editorBot) { BotEditorView(bot: $0) }
    }
}
