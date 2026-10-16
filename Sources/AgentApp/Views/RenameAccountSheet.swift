import SwiftUI

/// P48: Rename… for one connected account. The name is saved as the account's alias at Composio; an empty name puts
/// back the automatic one (who the account is, or "<App> account <n>").
struct RenameAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var apps: ConnectedAppsStore
    let account: ComposioAccount
    @State var name: String

    init(apps: ConnectedAppsStore, account: ComposioAccount) {
        self.apps = apps; self.account = account; _name = State(initialValue: account.alias ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(apps.appName(account.toolkit)) account").font(.title3.weight(.semibold))
            Text("Your bots and approval cards use this name. Leave it empty to use the automatic name.").font(.callout).foregroundStyle(.secondary)
            TextField(account.label, text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            if let error = apps.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if apps.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(apps.busy || name.count > ConnectedAppsStore.aliasLimit)
            }
        }.padding(22).frame(width: 400)
    }

    private func save() {
        Task { await apps.rename(account, to: name); if apps.error == nil { dismiss() } }
    }
}
