import SwiftUI

/// The small star a Herdr server's main bot wears beside its name: in the sidebar, the chat header and its Overview.
/// `label` says whose main bot it is ("Main bot of This Mac"), as the tooltip and for VoiceOver.
struct HerdrMainBotStar: View {
    let label: String; var size: CGFloat = 10
    var body: some View {
        Image(systemName: "star.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(Color.accentColor)
            .help(label).accessibilityLabel(label)
    }
}

/// Above the composer of a server's main bot. First the bots it created on its own decision, each with Remove and
/// Keep, so nothing it adds goes unseen. Then each bot its replies ask the person about, with Create and Dismiss:
/// nothing of those is created until Create is pressed, and a name already on the server can only be dismissed.
struct HerdrBotRequestCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var manager: Bot
    @State private var creating: Set<String> = []

    var body: some View {
        let pending = store.pendingHerdrBots(for: manager), unasked = store.herdrUnaskedBots(of: manager)
        if !pending.isEmpty || !unasked.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !unasked.isEmpty {
                    Text("\(manager.name) created \(unasked.count == 1 ? "a bot" : "\(unasked.count) bots") on \(store.herdrServer(for: manager).name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(unasked) { bot in
                        HStack(alignment: .top, spacing: 10) {
                            BotAvatar(bot: bot, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name).font(.callout.weight(.medium))
                                Text(bot.persona == Bot.defaultPersona ? "No instructions: it starts with the default ones." : bot.persona).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { store.removeHerdrBot(bot, createdBy: manager) }.help("Deletes \(bot.name) and its chat")
                            Button("Keep") { store.keepHerdrBot(bot) }
                        }
                    }
                }
                if !pending.isEmpty {
                    Text("\(manager.name) wants to create \(pending.count == 1 ? "a bot" : "\(pending.count) bots") on \(store.herdrServer(for: manager).name)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                                    if let runtime = item.request.runtime { Text(runtime).font(.caption).foregroundStyle(.secondary) }
                                    if let asker = item.askerID.flatMap({ id in store.bots.first { $0.id == id }?.name }) { Text("asked for by \(asker)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(item.taken ? "A bot with this name is already on this server." : item.request.instructions.isEmpty ? "No instructions: it starts with the default ones." : item.request.instructions)
                                    .font(.caption).foregroundStyle(item.taken ? .orange : .secondary).lineLimit(4).textSelection(.enabled)
                            }
                            Spacer()
                            if creating.contains(item.id) { ProgressView().controlSize(.small) }
                            else {
                                Button("Dismiss") { store.refuseHerdrBot(item, manager: manager) }
                                if !item.taken { Button("Create") { create(item) }.buttonStyle(.borderedProminent) }
                            }
                        }
                    }
                }
            }.padding(10).background(AppColor.card, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColor.separator, lineWidth: 0.5))
                .padding(.horizontal, 24).frame(maxWidth: 768)
        }
    }

    private func create(_ item: AppStore.PendingHerdrBot) {
        creating.insert(item.id)
        Task { await store.acceptHerdrBot(item, manager: manager); creating.remove(item.id) }
    }
}
