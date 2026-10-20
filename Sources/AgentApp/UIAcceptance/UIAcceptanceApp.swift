#if DEBUG
import SwiftUI

@MainActor final class UIAcceptanceController: ObservableObject {
    let store: AppStore
    let backend: UIAcceptanceBackend
    let directory: URL
    let local: Bot
    let remote: Bot

    init(directory: URL) throws {
        let fake = UIAcceptanceBackend(directory: directory)
        guard let defaults = UserDefaults(suiteName: directory.appending(path: "preferences").path) else {
            throw UIAcceptanceError.unsafeDependency
        }
        let url = directory.appending(path: "store.json")
        try UIAcceptanceIsolation.validate(backend: UIAcceptanceChatBackend(), keys: fake.keys, autoConfigure: false,
                                           storeURL: url, root: directory, isolatedDefaults: defaults !== UserDefaults.standard,
                                           hermesURL: defaults.string(forKey: "hermesBaseURL"), connectors: [])
        let appStore = AppStore(storeURL: url, autoConfigureHermes: false, backendFactory: { _ in UIAcceptanceChatBackend() },
                                keyStore: fake.keys, defaults: defaults)
        appStore.uiAcceptance = fake
        appStore.managedControl = { bot, verb, task, input in try fake.control(bot: bot, verb: verb, task: task, input: input) }
        let localBot = Bot(name: "Managed approval", backend: .hermes, hermesProfile: "acceptance")
        let remoteBot = Bot(name: "Remote approval (simulated)", backend: .hermes, hermesProfile: "acceptance")
        // A display/binding fixture only; the fake control handles it before any network transport is selected.
        remoteBot.hermesBaseURL = "https://acceptance.invalid"
        self.directory = directory; backend = fake; store = appStore; local = localBot; remote = remoteBot
        store.bots = [local, remote]; store.selectedBot = local
        try resetApprovals()
        resetDraft()
        backend.secretPrompt = SecretRequestPrompt(botID: local.id, conversationID: local.id,
            request: SecretRequest(name: "dummy-key", reason: "Acceptance fixture: use a dummy value only."))
        print("UI acceptance evidence: \(directory.path)")
    }

    func resetApprovals() throws {
        guard store.managedDecisionsInFlight.isEmpty else { return }
        store.approvals = try [backend.seed(bot: local, remote: false), backend.seed(bot: remote, remote: true)]
        store.save()
    }
    func resetDraft() {
        local.messages = [ChatMessage(role: .assistant, content: """
        ```draft
        To: a@example.invalid
        Subject: Acceptance draft

        Dummy message. Nothing is sent.
        ```
        """)]
        store.objectWillChange.send(); store.save()
    }
}

@MainActor struct UIAcceptanceApp: App {
    @StateObject private var controller: UIAcceptanceController
    init() {
        // Throwing work stays outside StateObject's @autoclosure; a failure refuses the launch (exit 78).
        let made: UIAcceptanceController
        do { made = try UIAcceptanceController(directory: UIAcceptanceIsolation.activate()) }
        catch { UIAcceptanceMode.refuse(error.localizedDescription) }
        _controller = StateObject(wrappedValue: made)
    }
    var body: some Scene {
        WindowGroup("Swarm Hub · UI acceptance") {
            UIAcceptanceWorkspace(controller: controller, store: controller.store, backend: controller.backend)
                .frame(minWidth: 780, minHeight: 620)
        }
    }
}

private struct UIAcceptanceWorkspace: View {
    @ObservedObject var controller: UIAcceptanceController
    @ObservedObject var store: AppStore
    @ObservedObject var backend: UIAcceptanceBackend
    var body: some View {
        VStack(spacing: 0) {
            Text(UIAcceptanceMode.banner).font(.headline).foregroundStyle(.black)
                .padding(12).frame(maxWidth: .infinity).background(.orange)
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Managed and remote approval fixtures").font(.title2)
                        Text("Approve or Decline changes only the bound in-process operation. The remote origin is a fixture.")
                        ForEach(store.approvals) { request in
                            ApprovalCard(request: request) { store.decide(request, approved: $0) }
                                .disabled(store.managedDecisionsInFlight.contains(request.id))
                            DisclosureGroup("Bound operation details") {
                                Text(request.command ?? "Unavailable").font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Text(request.routeNote ?? "").font(.caption).textSelection(.enabled)
                            }
                        }
                        ForEach(Array(backend.decisions.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).textSelection(.enabled)
                        }
                        Button("Reset approval fixtures") {
                            do { try controller.resetApprovals() } catch { store.errorMessage = error.localizedDescription }
                        }
                    }.padding(20)
                }.tabItem { Text("Approvals") }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Secure key sheet").font(.title2)
                    Text("Use a dummy key. It stays in memory until you quit; no Keychain item or secret file is written.")
                    Button("Open secure key sheet") { store.secretRequest = backend.secretPrompt }
                    if backend.secretSaved { Text("Dummy key saved in memory. Nothing was sent.") }
                    Spacer()
                }.padding(20).tabItem { Text("Secure key") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Draft Send").font(.title2)
                        ForEach(controller.local.messages) { message in
                            MarkdownContent(message: message, actionTarget: .bot(botID: controller.local.id, threadID: nil))
                        }
                        ForEach(backend.attempts) { attempt in
                            Text("Attempt \(attempt.id): simulated:true, delivered:false")
                                .font(.caption).textSelection(.enabled)
                        }
                        Button("New draft fixture") { controller.resetDraft() }
                    }.padding(20)
                }.tabItem { Text("Draft Send") }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red).padding(8) }
            Text("Evidence: \(controller.directory.path)").font(.caption).textSelection(.enabled).padding(8)
        }
        .environmentObject(store).defaultAppStorage(store.defaults)
        .sheet(item: $store.secretRequest) { SecretEntrySheet(prompt: $0) }
    }
}
#endif
