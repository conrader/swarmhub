import SwiftUI

/// The main bot's "+" menu in its composer: ask for a new bot, or have it get to know you.
struct ManageBotsMenu<Label: View>: View {
    let actions: [ManageBotsAction]; let perform: (ManageBotsAction) -> Void; @ViewBuilder let label: () -> Label
    var body: some View {
        Menu {
            ForEach(actions) { action in Button(action.title, systemImage: action.systemImage) { perform(action) } }
        } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            .help("Ask for a new bot, or let it get to know you").accessibilityLabel("More")
    }
}
