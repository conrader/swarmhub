import SwiftUI

/// The star that identifies a Herdr server's main bot on its avatar and in settings.
/// `label` says whose main bot it is ("Main bot of This Mac"), as the tooltip and for VoiceOver.
struct HerdrMainBotStar: View {
    let label: String; var size: CGFloat = 10
    var body: some View {
        Image(systemName: "star.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(.tint)
            .help(label).accessibilityLabel(label)
    }
}

/// Above the composer of a server's main bot. First the bots it created on its own decision, each with Remove and
/// Keep, so nothing it adds goes unseen. Then each bot its replies ask the person about, with Create and Dismiss:
/// nothing of those is created until Create is pressed, and a name already on the server can only be dismissed.
struct HerdrBotRequestCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var manager: Bot
    var showsCreatedBots = true
    @State private var creating: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pending = store.pendingHerdrBots(for: manager)
        let unasked = showsCreatedBots ? store.herdrUnaskedBots(of: manager) : []
        // A card that arrives or leaves does so gently, so the message box does not jump.
        Group { card(pending, unasked) }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: pending.count + unasked.count)
    }

    @ViewBuilder private func card(_ pending: [AppStore.PendingHerdrBot], _ unasked: [Bot]) -> some View {
        if !pending.isEmpty || !unasked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !unasked.isEmpty {
                    Text("\(manager.name) created \(unasked.count == 1 ? "a bot" : "\(unasked.count) bots") for you").font(.caption.weight(.semibold)).foregroundStyle(manager.tintInk)
                    ForEach(unasked) { bot in
                        HStack(alignment: .top, spacing: 10) {
                            BotAvatar(bot: bot, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name).font(.callout.weight(.medium))
                                if let cap = bot.sessionCapCents { Text(HerdrBotRequest.capLabel(cap)).font(.caption) }
                                FoldedWords(text: bot.persona == Bot.defaultPersona ? "No special instructions." : bot.persona, name: "instructions")
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeHerdrBot(bot, createdBy: manager) }.help("Deletes \(bot.name) and its chat, and ends its agent")
                            Button("Keep") { store.keepHerdrBot(bot) }
                        }
                    }
                }
                if !pending.isEmpty {
                    Text("\(manager.name) suggests \(pending.count == 1 ? "a new bot" : "\(pending.count) new bots")").font(.caption.weight(.semibold)).foregroundStyle(manager.tintInk)
                    ForEach(pending) { item in
                        HStack(alignment: .top, spacing: 10) {
                            // The requested look when the app can draw it; otherwise the new bot gets its own, like any new bot.
                            if let shape = item.request.shape, AvatarShape.isValid(shape), let colour = item.request.colour.flatMap(AvatarColour.init(rawValue:)) {
                                AvatarMarkView(shape: shape, colour: colour, size: 30, mode: .still, seed: item.id)
                            } else {
                                Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary).frame(width: 30, height: 30)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(item.request.name).font(.callout.weight(.medium))
                                    Text([item.request.runtime, item.request.model ?? "Recommended model"].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    if let asker = item.askerID.flatMap({ id in store.bots.first { $0.id == id }?.name }) { Text("asked for by \(asker)").font(.caption).foregroundStyle(.secondary) }
                                }
                                if let cap = item.request.sessionCapCents { Text(HerdrBotRequest.capLabel(cap)).font(.caption) }
                                if let reason = item.request.reviewReason {
                                    Label("Sensitive role", systemImage: "hand.raised").font(.caption.weight(.semibold)).foregroundStyle(AppColor.caution)
                                    Text(verbatim: reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    Text("Each tool call requires approval. Switching to Claude uses its recommended model.").font(.caption).foregroundStyle(.secondary)
                                }
                                if item.taken { Text("You already have a bot with this name. Ask \(manager.name) for another name.").font(.caption).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true) }
                                else { FoldedWords(text: item.request.instructions.isEmpty ? "No special instructions." : item.request.instructions, name: "instructions") }
                            }
                            Spacer()
                            if creating.contains(item.id) { ProgressView().controlSize(.small) }
                            else {
                                Button("Not now") { store.refuseHerdrBot(item, manager: manager) }
                                    .accessibilityLabel(showsCreatedBots ? "Not now" : "Dismiss proposal for " + item.request.name)
                                if !item.taken {
                                    Button(item.request.reviewReason == nil ? "Create" : "Create with Claude") { create(item) }.buttonStyle(.appleProminent)
                                        .accessibilityLabel("Create " + item.request.name + (item.request.reviewReason == nil ? "" : " with Claude"))
                                }
                            }
                        }
                    }
                }
            }.chatCard(tint: manager.colours).transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func create(_ item: AppStore.PendingHerdrBot) {
        creating.insert(item.id)
        Task { await store.acceptHerdrBot(item, manager: manager); creating.remove(item.id) }
    }
}
