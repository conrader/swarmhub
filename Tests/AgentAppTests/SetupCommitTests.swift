import Foundation
import Testing
@testable import AgentApp

// P38: `SetupTransaction`, the rollback journal behind the setup window's Add (Hermes and OpenClaw).

@MainActor private func storeThatCannotSave(keys: InMemoryKeyStore, defaults: UserDefaults) throws -> AppStore {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(UUID().uuidString)")
    try Data("not a folder".utf8).write(to: blocker)
    return AppStore(storeURL: blocker.appending(path: "store.json"), autoConfigureHermes: false, keyStore: keys, defaults: defaults)
}

@MainActor @Test func journalUndoesEveryStepNewestFirst() throws {
    let keys = InMemoryKeyStore(["hermes": "old"]), defaults = isolatedDefaults()
    defaults.set("kept", forKey: "present")
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults)
    let bot = Bot(name: "A", backend: .hermes, hermesProfile: "a"); store.bots = [bot]; store.selectedBot = bot
    store.prefixIgnoredHermesProfiles = ["ignored"]
    var order: [Int] = []
    let transaction = SetupTransaction(store)
    struct Boom: Error {}
    #expect(throws: AppStore.SetupCommitError.saveFailed) {
        try transaction.run {
            transaction.captureDefaults(["present", "absent"]); transaction.captureBots()
            transaction.record { order.append(1) }; transaction.record { order.append(2) }
            defaults.set("changed", forKey: "present"); defaults.set("new", forKey: "absent")
            transaction.setKey("new", for: "hermes"); transaction.setKey("added", for: "hermes.extra")
            bot.hermesProfile = "b"; bot.isHidden = true; store.bots.append(Bot(name: "B")); store.selectedBot = nil
            store.prefixIgnoredHermesProfiles = []
            throw Boom()
        }
    }
    #expect(order == [2, 1])
    #expect(defaults.string(forKey: "present") == "kept" && defaults.object(forKey: "absent") == nil)
    #expect(keys.all() == ["hermes": "old"], "a replaced key comes back, an added one goes")
    #expect(store.bots.map(\.id) == [bot.id] && bot.hermesProfile == "a" && !bot.isHidden && store.selectedBot === bot)
    #expect(store.prefixIgnoredHermesProfiles == ["ignored"])

    let done = SetupTransaction(store)
    try done.run { done.setKey("kept", for: "hermes") }
    done.rollback()
    #expect(keys.key(for: "hermes") == "kept", "a finished transaction has nothing left to undo")
}

@MainActor @Test func aFailedHermesAddRestoresIgnoredProfilesAndKeys() async throws {
    let (host, session) = MockHermesProtocol.serve { request in
        let path = request.url!.path
        if path == "/health/detailed" { return (200, ["version": "0.21.7", "status": "ok"]) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.suffix(2) == ["v1", "models"] else { return (404, ["error": "no route"]) }
        let profile = parts.count == 4 && parts[0] == "p" ? parts[1] : "default"
        return (200, ["data": [["id": profile == "default" ? "hermes-agent" : profile]]])
    }
    let result = await SetupCheck.run(.init(address: "https://\(host)", key: "main-key", extra: "research=research-key"), session: session)
    let keys = InMemoryKeyStore(), defaults = isolatedDefaults()
    let store = try storeThatCannotSave(keys: keys, defaults: defaults)
    store.prefixIgnoredHermesProfiles = ["research"]
    #expect(throws: AppStore.SetupCommitError.saveFailed) { try store.commitSetup(result, key: "main-key", chosen: ["default", "research"], confirmMove: false) }
    #expect(store.prefixIgnoredHermesProfiles == ["research"], "the ignored list is part of the rollback")
    #expect(keys.all().isEmpty && defaults.object(forKey: "hermesBaseURL") == nil && defaults.object(forKey: "hermesProfiles") == nil)
    #expect(store.bots.isEmpty && FirstRun.state(defaults) != .done)
}
