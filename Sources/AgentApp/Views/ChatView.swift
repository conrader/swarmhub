import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot; @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                BotAvatar(bot: bot, size: 30)
                Button { store.showInfo.toggle() } label: { Text(bot.name).font(.system(size: 14, weight: .semibold)) }.buttonStyle(.plain)
                Spacer()
            }.padding(.horizontal, 20).frame(height: 54).background(.background)
            Divider().opacity(0.5)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        Color.clear.frame(height: 20)
                        ForEach(Array(bot.messages.enumerated()), id: \.element.id) { index, message in
                            MessageView(message: message).id(message.id)
                            if index == 1 { ForEach(store.approvals) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) } }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity)
                }.background(.background)
                .onChange(of: bot.messages.last?.content) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: bot.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            ComposerView(text: $draft, isStreaming: store.isStreaming, send: send).background(.background)
        }
    }
    private func send() { let value = draft; guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; draft = ""; store.send(text: value) }
}
