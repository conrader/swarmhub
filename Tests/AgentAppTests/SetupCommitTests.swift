import Foundation
import Testing
@testable import AgentApp

// `SetupTransaction`, the rollback journal behind the setup wizard's last button.

@MainActor private func storeThatCannotSave(keys: InMemoryKeyStore, defaults: UserDefaults) throws -> AppStore {
    let blocker = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(UUID().uuidString)")
    try Data("not a folder".utf8).write(to: blocker)
    return AppStore(storeURL: blocker.appending(path: "store.json"), autoStart: false, keyStore: keys, defaults: defaults)
}

