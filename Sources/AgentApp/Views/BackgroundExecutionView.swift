import SwiftUI

/// P38 B: background app access (a scoped worker on an agent's server asking for app actions while this Mac is closed).
/// P40: the SwarmHub routes for it are not deployed, so the section says so in one line: no sign-in, no dead controls.
/// `BackgroundExecutionClient` and `AppStore.refreshBackgroundInbox` stay ready for when the routes exist.
struct BackgroundExecutionView: View {
    var body: some View {
        Section("Background app access") {
            Text(ConnectedAppsCopy.backgroundNotAvailable).font(.callout).foregroundStyle(.secondary)
        }
    }
}
