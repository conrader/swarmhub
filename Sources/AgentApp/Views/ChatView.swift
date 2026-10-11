import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var store: AppStore
    let bot: Bot
    @State private var draft = ""
    private var messages: [ChatMessage] { bot.messages }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) { Text(bot.name).font(.headline); Text(store.statusText.isEmpty ? bot.backend.rawValue : store.statusText).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("View", selection: $store.selectedMode) { Text("Chat").tag(0); Text("Computer").tag(1) }.pickerStyle(.segmented).frame(width: 190)
                Button { store.showSubAgents.toggle() } label: { Image(systemName: "sidebar.right") }.help("Toggle sub-agents")
            }.padding(12).background(.bar)
            Divider()
            if store.selectedMode == 1 { ComputerView() }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { MessageView(message: $0).id($0.id) }
                            ForEach(store.approvals) { request in ApprovalCard(request: request) { store.decide(request, approved: $0) }.id(request.id) }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(.vertical, 8)
                    }
                    .onChange(of: messages.last?.content) { _, _ in withAnimation(.linear(duration: 0.08)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                ComposerView(text: $draft, isStreaming: store.isStreaming, send: send, stop: store.stop)
            }
        }
    }
    private func send() { let value = draft; draft = ""; store.send(text: value) }
}
