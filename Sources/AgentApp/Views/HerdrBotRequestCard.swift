import SwiftUI

/// Above the composer of a Herdr bot that may create bots: each bot its newest reply asked for, with Create and
/// Dismiss. Nothing is created until Create is pressed; a name already on the server can only be dismissed.
struct HerdrBotRequestCard: View {
    @EnvironmentObject private var store: AppStore; @ObservedObject var manager: Bot
    @State private var creating: Set<String> = []

    var body: some View {
        let pending = store.pendingHerdrBots(for: manager)
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
                            }
                            Text(item.taken ? "A bot with this name is already on this server." : item.request.instructions.isEmpty ? "No instructions: it starts with the default ones." : item.request.instructions)
                                .font(.caption).foregroundStyle(item.taken ? .orange : .secondary).lineLimit(4).textSelection(.enabled)
                        }
                        Spacer()
                        if creating.contains(item.id) { ProgressView().controlSize(.small) }
                        else {
                            Button("Dismiss") { store.dismissHerdrBot(item) }
                            if !item.taken { Button("Create") { create(item) }.buttonStyle(.borderedProminent) }
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
