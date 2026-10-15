import SwiftUI

/// P42: one exchange the user didn't start, inline in the bot's main chat where it happened: "Woken by: Jarvis ·
/// Open conversation", the "From Jarvis" bubble with the message, the steps as they unfold (P29 Steps row, live while it
/// runs), then the reply. The exchange itself stays in its own Hermes session.
struct BotExchangeCard: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var message: ChatMessage
    var stepsExpanded = false

    static func isExchange(_ message: ChatMessage) -> Bool { BotWorkOrigin(raw: message.metadata[BotWorkKey.origin]) != nil }

    var body: some View {
        let origin = BotWorkOrigin(raw: message.metadata[BotWorkKey.origin]) ?? .bot(message.metadata[BotMessageKey.from] ?? "")
        let to = message.metadata[BotMessageKey.to] ?? "", session = message.metadata[BotMessageKey.session] ?? ""
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let profile = origin.profile { BotMark(profile: profile, size: 16) } else { Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary) }
                Text(BotWorkCopy.wokenBy(origin, name: store.displayName(forProfile:))).foregroundStyle(.secondary)
                if let from = origin.profile {
                    Text("·").foregroundStyle(.tertiary)
                    Button(BotMessageCopy.openThread) { store.openThread(BotThreadKey(from: from, to: to, session: session)) }.buttonStyle(.link)
                }
                Text(message.createdAt, style: .time).foregroundStyle(.tertiary)
            }.font(.caption)
            if let request = message.metadata[BotWorkKey.request], !request.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if let from = origin.profile {
                        Text(BotWorkCopy.from(store.displayName(forProfile: from))).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(request).textSelection(.enabled).lineLimit(12).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            if message.isStreaming {
                Label(BotWorkCopy.workingFor(origin, name: store.displayName(forProfile:)), systemImage: "gearshape.2").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ActivityRow(message: message, expanded: stepsExpanded || message.isStreaming)
            if let reply = message.metadata[BotWorkKey.reply], !reply.isEmpty {
                MarkdownContent(message: message, text: reply)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColor.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppColor.separator, lineWidth: 0.5))
    }
}
