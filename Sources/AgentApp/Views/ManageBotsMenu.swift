import SwiftUI

/// "Manage bots" in the main bot's composer: each item fills the composer with a plain request.
struct ManageBotsMenu<Label: View>: View {
    let actions: [ManageBotsAction]; let perform: (ManageBotsAction) -> Void; @ViewBuilder let label: () -> Label
    var body: some View {
        Menu {
            Section("Manage bots") {
                ForEach(actions) { action in Button(action.title, systemImage: action.systemImage) { perform(action) } }
            }
        } label: { label() }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            .help("Manage bots").accessibilityLabel("Manage bots")
    }
}
