import Combine
import Foundation

extension AppStore {
    private func personSettingsKey(_ server: HerdrServer) -> String {
        // Include the destination so editing an existing server cannot carry over location consent.
        "personSettings.\(server.id).\(server.kind.rawValue).\(server.place).\(server.address)"
    }

    func personSettings(for server: HerdrServer) -> HerdrPersonSettings {
        let key = personSettingsKey(server)
        if let model = personSettingsModels[key] { return model }
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(PersonSettingsPreferences.self, from: $0) }
        let client: () throws -> HerdrClient = { [weak self] in
            guard let self, let current = herdrServers.first(where: { personSettingsKey($0) == key }) else { throw CancellationError() }
            return try herdrClient(for: current)
        }
        let model = HerdrPersonSettings(
            preferences: saved ?? PersonSettingsPreferences(),
            load: { try await client().personProfile() },
            update: { try await client().updatePersonProfile(timezone: $0, location: $1) },
            locate: { await DevicePersonLocation.current(askForPermission: $0) },
            persist: { [weak self] in self?.defaults.set(try? JSONEncoder().encode($0), forKey: key) },
            onZoneChange: { [weak self] in self?.objectWillChange.send() }
        )
        personSettingsModels[key] = model
        return model
    }

    func startPersonSettings() {
        personTimezoneObserver = NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange).sink { [weak self] _ in
            Task { @MainActor in self?.refreshPersonSettings() }
        }
        refreshPersonSettings()
    }

    func refreshPersonSettings() {
        guard launchWorkEnabled, !isSetupPreview else { return }
        for server in herdrServers { personSettings(for: server).refresh() }
    }

    var personDisplayZone: TimeZone {
        let bot = selectedGroup.flatMap { group in bots.first { group.memberIDs.contains($0.id) } } ?? selectedBot
        let server = bot.map { herdrServer(for: $0) } ?? herdrServers[0]
        return personSettings(for: server).displayZone
    }
}
