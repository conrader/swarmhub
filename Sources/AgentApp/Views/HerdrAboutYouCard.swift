import SwiftUI

/// Above the main bot's composer: what it would like to remember about the person, one sentence per row, each with
/// Remember and Don't save. Nothing joins "About you" until Remember is pressed; the text itself is in Settings →
/// General, where the person can read and change all of it.
struct HerdrAboutYouCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot
    @State private var problem = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pending = store.pendingAboutYou(for: bot)
        Group {
            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(AboutYouCopy.cardTitle(bot.name), systemImage: "person.text.rectangle").font(.caption.weight(.semibold)).foregroundStyle(bot.tintInk)
                    ForEach(pending) { item in
                        HStack(alignment: .center, spacing: 10) {
                            Text(item.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(AboutYouCopy.dismiss) { problem = ""; store.dismissAboutYou(item) }
                            Button(AboutYouCopy.save) { problem = store.acceptAboutYou(item) ? "" : AboutYouCopy.full }.buttonStyle(.borderedProminent)
                        }
                    }
                    if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true) }
                }
                .chatCard(tint: bot.colours).transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pending)
    }
}

/// The quiet offer a main bot shows once when it has never introduced itself (a bot from before this existed, or
/// one the wizard kept): Start has it ask its few questions, Not now puts the offer away for good. "Get to know
/// me" in the composer's + menu stays.
struct HerdrIntroOffer: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var bot: Bot

    var body: some View {
        if store.offersHerdrIntro(bot) {
            HStack(alignment: .center, spacing: 12) {
                BotAvatar(bot: bot, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AboutYouCopy.offerTitle(bot.name)).font(.callout.weight(.semibold))
                    Text(AboutYouCopy.offerDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(AboutYouCopy.offerLater) { store.dismissHerdrIntro(bot) }
                Button(AboutYouCopy.offerStart) { store.chatScroll.toBottom(bot.id); store.startHerdrIntro(for: bot) }.buttonStyle(.borderedProminent)
            }.chatCard(tint: bot.colours)
        }
    }
}
