import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BotAvatar(bot: bot, size: 36)
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.showInfo.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 1) { HStack(spacing: 5) { Text(bot.name).font(.headline); Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary) }; Text(store.statusText.isEmpty ? bot.title : store.statusText).font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.plain)
                Spacer()
                Button { store.showCommandPalette = true } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Command palette (⌘K)")
                Button { withAnimation(.easeInOut(duration: 0.2)) { store.showInfo.toggle() } } label: { Image(systemName: "sidebar.right") }.buttonStyle(.plain).foregroundStyle(store.showInfo ? Color.accentColor : .secondary).help("Agent info (⇧⌘I)")
            }.padding(.horizontal, 20).frame(height: 62).background(.background)
            Divider().opacity(0.65)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        HStack { Text("Today").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 4).background(.quaternary.opacity(0.6), in: Capsule()) }.padding(.vertical, 16)
                        ForEach(Array(bot.messages.enumerated()), id: \.element.id) { index, message in
                            MessageView(message: message).id(message.id)
                            if index == 1 { ForEach(store.approvals) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) } }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 760).frame(maxWidth: .infinity)
                }.background(Color(nsColor: .textBackgroundColor).opacity(0.38))
                .onChange(of: bot.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: bot.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            ComposerView(text: $draft, isStreaming: store.isStreaming, send: send, stop: store.stop).background(.background)
        }
    }
    private func send() { let value = draft; guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; draft = ""; store.send(text: value) }
}
