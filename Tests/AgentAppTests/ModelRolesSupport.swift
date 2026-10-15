import Foundation
@testable import AgentApp

// P13 model roles: synthetic gateways and stores. Names are made up (`lab-one`, `router`, `model-alpha`,
// `model-beta`, `model-coder`); provider credentials never appear. Catalogs come from `catalogPayload(_:)`, which
// emits a 0.20.5-shaped and a 0.21.x-shaped payload.

/// Names used only by the role tests; none may appear in `Sources/`.
let roleFixtureNames = ["model-coder", "lab-coder"]

/// `PickerServer` plus a `delegation` toolset per profile (true on, false off, absent = not listed).
func rolesHandler(_ server: PickerServer, delegation: [String: Bool]) -> MockHermesProtocol.Handler {
    let base = server.handler
    return { request in
        let parts = request.url!.path.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "p", parts[2...] == ["v1", "toolsets"], let enabled = delegation[parts[1]],
           request.value(forHTTPHeaderField: "Authorization") == "Bearer \(server.keys[parts[1]] ?? "-")" {
            return (200, ["object": "list", "data": [["name": "web", "label": "Web", "enabled": true],
                                                     ["name": "delegation", "label": "Delegation", "enabled": enabled, "tools": ["delegate_task"]]]])
        }
        return base(request)
    }
}

/// Jarvis (`grok-jarvis`, session s1) and Rapper (`grok-rapper`, session r1) on one synthetic box.
@MainActor func rolesStore(_ server: PickerServer, delegation: [String: Bool] = [:], jarvisSession: String? = "s1") -> (store: AppStore, jarvis: Bot, rapper: Bot, host: String, storeURL: URL) {
    let (host, session) = MockHermesProtocol.serve(rolesHandler(server, delegation: delegation))
    let defaults = isolatedDefaults(); defaults.set("https://\(host)/v1", forKey: "hermesBaseURL")
    var keys = ["hermes": "default-key"]
    for (profile, key) in server.keys { keys["hermes.\(profile)"] = key }
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: defaults, hermesSession: session)
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis", hermesSessionID: jarvisSession)
    let rapper = Bot(name: "Rapper", backend: .hermes, hermesProfile: "grok-rapper", hermesSessionID: "r1")
    store.bots = [jarvis, rapper]
    return (store, jarvis, rapper, host, url)
}

func rolePaths(_ host: String) -> [String] { MockHermesProtocol.recorded(host).map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }

// MARK: Apply (Part B)

let applyFeatures: [String: Bool] = ["session_chat_streaming": true, "model_options": true, "session_model_lock": true, "session_fork": true, "skills_api": false]
let applyKeys = ["grok-jarvis": "jarvis-key-77", "grok-dmt": "dmt-key-88", "grok-achilles": "achilles-key-99"]

/// A stateful synthetic gateway (`E2EServer`: create, session rows, lock with a status switch, chat stream) serving
/// `catalogPayload(shape)`, and Jarvis, DMT and Achilles on `grok-*` profiles, each with its own key.
@MainActor func applyStore(_ shape: CatalogShape, features: [String: Bool] = applyFeatures) -> (store: AppStore, jarvis: Bot, dmt: Bot, achilles: Bot, state: E2EServer.State, url: URL) {
    let server = E2EServer.serve(features: features)
    server.state.with { $0.catalog = catalogPayload(shape) }
    let defaults = isolatedDefaults(); defaults.set("https://\(server.host)", forKey: "hermesBaseURL")
    var keys = ["hermes": "default-key-55"]
    for (profile, key) in applyKeys { keys["hermes.\(profile)"] = key }
    let url = temporaryStore()
    let store = AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore(keys), defaults: defaults, hermesSession: server.session)
    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis")
    let dmt = Bot(name: "DMT", backend: .hermes, hermesProfile: "grok-dmt")
    let achilles = Bot(name: "Achilles", backend: .hermes, hermesProfile: "grok-achilles")
    store.bots = [jarvis, dmt, achilles]; store.groups = []
    return (store, jarvis, dmt, achilles, server.state, url)
}

/// Sends `text` from `bot`'s main chat and waits until the turn has ended.
@MainActor func sendAndWait(_ store: AppStore, _ bot: Bot, _ text: String) async throws {
    store.selectedBot = bot; store.selectedGroup = nil
    precondition(store.send(text: text), "send refused")
    try await waitUntil { !store.anyTurnRunning }
}

func lines(_ state: E2EServer.State, from mark: Int = 0) -> [String] { state.requests().dropFirst(mark).map { "\($0.method) \($0.path)" } }
func lockPosts(_ state: E2EServer.State) -> [(path: String, body: [String: Any])] {
    state.requests().filter { $0.method == "POST" && $0.path.hasSuffix("/model") }.map { ($0.path, $0.body ?? [:]) }
}
