import SwiftUI

@main
struct SwarmHubApp: App {
    @State private var store = MobileStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "Dark"
    var body: some Scene {
        WindowGroup {
            RootView().environment(store)
                .preferredColorScheme(appearance == "System" ? nil : appearance == "Light" ? .light : .dark)
                .tint(.primary)
                .task { await store.load() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await store.background() } }
                    if phase == .active { Task { for profile in store.profiles where profile.sessionID != nil { await store.refresh(profile.id) } } }
                }
        }
    }
}
