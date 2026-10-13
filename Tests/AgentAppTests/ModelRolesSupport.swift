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
