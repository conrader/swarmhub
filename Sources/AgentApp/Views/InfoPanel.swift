import SwiftUI

struct InfoPanel: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var bot: Bot
    @State private var computerPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { store.showInfo = false } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help("Close")
            }.padding(.horizontal, 14).frame(height: 54)
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    BotAvatar(bot: bot, size: 38)
                    VStack(alignment: .leading, spacing: 2) { Text(bot.name).font(.system(size: 14, weight: .semibold)); Text(bot.title).font(.system(size: 12)).foregroundStyle(.secondary) }
                }
                if !bot.botDescription.isEmpty { Text(bot.botDescription).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(2) }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Computer").font(.system(size: 13, weight: .semibold)); Spacer(); Button { computerPresented = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.plain).help("Open full screen") }
                    Button { computerPresented = true } label: { ComputerView().frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.12), lineWidth: 0.5)).allowsHitTesting(false) }.buttonStyle(.plain)
                }
                Button("Edit bot") { store.editingBot = bot }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
            }.padding(14)
        }.frame(minWidth: 250, idealWidth: 270, maxWidth: 290).background(.background)
            .sheet(isPresented: $computerPresented) { ComputerView().frame(minWidth: 1000, minHeight: 680) }
    }
}
