import SwiftUI

/// A message the app put into this chat from another bot (its request for a new bot, its message, its answer) or
/// about one: who it is from, with that bot's face, and the words that are its own. The lines that only tell the
/// agent how to answer are sent with it and never drawn (`HerdrPassedOn`).
struct PassedOnCard: View {
    let row: AppStore.PassedOnRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let sender = row.sender { BotAvatar(bot: sender, size: 28) }
            else { Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, height: 28).background(Circle().fill(Color.primary.opacity(0.08))).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let name = row.shown.botName { Text(name).font(.headline) }
                if !row.shown.body.isEmpty { Text(row.shown.body).font(.callout).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: 520, alignment: .leading)
        .background((row.sender?.tint ?? AppColor.olive).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((row.sender?.tint ?? AppColor.olive).opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
