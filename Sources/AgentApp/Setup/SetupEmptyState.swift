import SwiftUI

/// The main window's empty detail, under the app's own mark: "Meet your first bot" with Set up and the sample link
/// while nothing real is connected, so Skip is never a dead end; otherwise "Who do you want to talk to?".
struct SetupEmptyState: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if FirstRun.hasRealAgents(store.bots) {
            VStack(spacing: 10) {
                SetupAppMark(size: 64).padding(.bottom, 4)
                Text(SimpleCopy.chooseTitle).font(.title2.bold())
                Text(SimpleCopy.chooseDetail).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColor.chat)
        } else {
            VStack(spacing: 10) {
                SetupAppMark(size: 84).padding(.bottom, 6)
                Text(SimpleCopy.emptyTitle).font(.system(size: 26, weight: .bold))
                Text(SimpleCopy.herdrEmptyDetail).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(SimpleCopy.emptySetUp) { store.openSetup(openWindow: openWindow) }.buttonStyle(.appleProminent).controlSize(.large).padding(.top, 10)
                Button("Bring my Grok bot") { store.openSetup(openWindow: openWindow, forGrok: true) }
                Button(SetupCopy.sampleLink) { store.loadSamples() }.buttonStyle(.plain).foregroundStyle(.tint)
            }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppColor.chat)
        }
    }
}
