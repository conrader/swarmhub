import SwiftUI

/// The main bot's "+" menu in its composer: its item fills the composer with a plain request for a new bot.
struct ManageBotsMenu<Label: View>: View {
    let actions: [ManageBotsAction]; let perform: (ManageBotsAction) -> Void; @ViewBuilder let label: () -> Label
    var body: some View {
        Menu {
            ForEach(actions) { action in Button(action.title, systemImage: action.systemImage) { perform(action) } }
        } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            .help("Ask for a new bot").accessibilityLabel("Ask for a new bot")
    }
}
