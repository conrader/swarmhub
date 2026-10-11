import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 5) {
                if message.role != .user { Text(message.role == .system ? "Activity" : "Assistant").font(.caption).foregroundStyle(.secondary) }
                Text(markdown).textSelection(.enabled).font(.body).lineSpacing(3)
                if message.isStreaming { ProgressView().controlSize(.mini) }
            }
            .padding(message.role == .user ? 10 : 2)
            .background(message.role == .user ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
            if message.role != .user { Spacer(minLength: 30) }
        }.padding(.horizontal, 16).padding(.vertical, 6)
    }
    private var markdown: AttributedString {
        (try? AttributedString(markdown: message.content, options: .init(interpretedSyntax: .full))) ?? AttributedString(message.content)
    }
}
