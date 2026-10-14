import SwiftUI

/// The main window's empty detail (P21 item 10): "Connect your agents" with Set up and the sample link while nothing
/// real is connected, so Skip is never a dead end; otherwise the usual "Choose an agent".
struct SetupEmptyState: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if FirstRun.hasRealAgents(store.bots) {
            ContentUnavailableView(SimpleCopy.chooseTitle, systemImage: "bubble.left.and.bubble.right", description: Text(SimpleCopy.chooseDetail))
        } else {
            ContentUnavailableView {
                Label(SimpleCopy.emptyTitle, systemImage: "link")
            } description: {
                Text(SimpleCopy.emptyDetail)
            } actions: {
                Button(SimpleCopy.emptySetUp) { store.openSetup(openWindow: openWindow) }.buttonStyle(.borderedProminent)
                Button(SetupCopy.sampleLink) { store.loadSamples() }.buttonStyle(.link)
            }
        }
    }
}
