import SwiftUI

@main
struct SwarmHubApp: App {
    @State private var store = MobileStore()
    @State private var managed = ManagedApprovalStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "Dark"
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).environment(managed)
                .preferredColorScheme((CaptureConfiguration.appearance ?? appearance) == "System" ? nil : (CaptureConfiguration.appearance ?? appearance) == "Light" ? .light : .dark)
                .tint(.primary)
                .task { await store.load() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await store.background() } }
                    if phase == .active { Task { for profile in store.profiles where profile.sessionID != nil { await store.refresh(profile.id) } } }
                }
        }
    }
}
