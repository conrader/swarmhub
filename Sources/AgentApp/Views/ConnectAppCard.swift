import SwiftUI

private struct ConnectAppBotKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var connectAppBotID: UUID? {
        get { self[ConnectAppBotKey.self] }
        set { self[ConnectAppBotKey.self] = newValue }
    }
}

/// P38 B: the `connect-app` card in a bot's reply. It opens `ConnectAppSheet` for the bot of the chat it sits in.
struct ConnectAppCard: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.connectAppBotID) private var botID
    @ObservedObject var message: ChatMessage
    let request: AppConnectionRequest
    @ObservedObject var apps: ConnectedAppsStore
    @State private var connecting = false

    private var bot: Bot? { store.connectionBot(id: botID) }
    private var app: ComposioToolkit? { apps.catalog.first { $0.id == request.toolkit } ?? ComposioToolkit.popular.first { $0.id == request.toolkit } }
    private var name: String { app?.name ?? request.toolkit }
    private var allowed: Bool { bot.map { apps.enabledToolkits(for: $0.id).contains(request.toolkit) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                // P48: the same logo as the Connect apps sheet's tiles.
                AppLogoView(slug: request.toolkit, name: name, logo: app?.logo ?? ComposioToolkit.publicLogo(request.toolkit), size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.callout.weight(.semibold))
                    if let bot { Text(allowed ? "Enabled for \(bot.name)" : "Connect an account for \(bot.name)").font(.caption).foregroundStyle(.secondary) }
                    else { Text("This bot is unavailable for app connections.").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if !apps.isAvailable { Text(ConnectedAppsCopy.serviceNotConfigured).font(.caption).foregroundStyle(.secondary) }
            if !request.reason.isEmpty { Text(request.reason).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text(allowed ? "Send a follow-up to continue." : "You choose the account and access.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(allowed ? "Manage" : "Connect \(name)") { connecting = true }
                    .buttonStyle(NeutralPrimaryButtonStyle())
                    .disabled(bot == nil || message.role != .assistant || message.isStreaming || store.conversation(containing: message.id).map(store.isStreaming(in:)) == true || !apps.canConfigure || !apps.isAvailable)
            }
        }.padding(14).frame(maxWidth: 500, alignment: .leading)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColor.separator, lineWidth: 0.5))
            .sheet(isPresented: $connecting) {
                if let botID { ConnectAppSheet(request: request, botID: botID, apps: apps).environmentObject(store) }
            }
    }
}
