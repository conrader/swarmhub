import Combine
import Foundation

struct PersonPlace: Codable, Equatable {
    enum Source: String, Codable { case manual, device }
    let city: String
    let region: String?
    let country: String?
    let source: Source

    var label: String { [city, region, country].compactMap { $0 }.joined(separator: ", ") }

    static func manual(city: String, region: String, country: String) -> Self? {
        func clean(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let city = clean(city) else { return nil }
        return Self(city: city, region: clean(region), country: clean(country), source: .manual)
    }

    var fields: [String: String] {
        var values = ["city": city, "source": source.rawValue]
        values["region"] = region
        values["country"] = country
        return values
    }
}

struct WorkspacePersonProfile: Decodable, Equatable {
    var timezone: String?
    var location: PersonPlace?
    var updatedAt: Int64?
}

struct PersonSettingsPreferences: Codable {
    var followsMac = true
    var pinnedZone: String?
    var usesDeviceLocation = false

    func timezone(macZone: String, workspaceZone: String?) -> String {
        followsMac ? macZone : pinnedZone ?? workspaceZone ?? macZone
    }
}

@MainActor final class HerdrPersonSettings: ObservableObject {
    enum LocationChange: Equatable {
        case set(PersonPlace), clear, clearDevice

        var fields: [String: Any] {
            switch self {
            case .set(let place): ["kind": "set", "place": place.fields]
            case .clear: ["kind": "clear"]
            case .clearDevice: ["kind": "clear_device"]
            }
        }
    }

    @Published private(set) var preferences: PersonSettingsPreferences
    @Published private(set) var profile = WorkspacePersonProfile()
    @Published private(set) var status: String?
    private(set) var locationTask: Task<Void, Never>?
    private(set) var updateTask: Task<Void, Never>?
    private let load: () async throws -> WorkspacePersonProfile
    private let update: (String?, LocationChange?) async throws -> WorkspacePersonProfile
    private let locate: (Bool) async -> PersonPlace?
    private let macZone: () -> String
    private let persist: (PersonSettingsPreferences) -> Void
    private let onZoneChange: () -> Void

    var zone: String { preferences.timezone(macZone: macZone(), workspaceZone: profile.timezone) }
    var displayZone: TimeZone { TimeZone(identifier: zone) ?? .autoupdatingCurrent }

    init(preferences: PersonSettingsPreferences,
         load: @escaping () async throws -> WorkspacePersonProfile,
         update: @escaping (String?, LocationChange?) async throws -> WorkspacePersonProfile,
         locate: @escaping (Bool) async -> PersonPlace?,
         macZone: @escaping () -> String = { TimeZone.autoupdatingCurrent.identifier },
         persist: @escaping (PersonSettingsPreferences) -> Void,
         onZoneChange: @escaping () -> Void = {}) {
        self.preferences = preferences
        self.load = load
        self.update = update
        self.locate = locate
        self.macZone = macZone
        self.persist = persist
        self.onZoneChange = onZoneChange
    }

    func followMac(_ follows: Bool) {
        let pinned = follows ? preferences.pinnedZone : zone
        preferences.followsMac = follows
        preferences.pinnedZone = pinned
        persist(preferences)
        send(timezone: zone)
        onZoneChange()
    }

    func pin(_ identifier: String) {
        guard !preferences.followsMac, TimeZone(identifier: identifier) != nil else { return }
        preferences.pinnedZone = identifier
        persist(preferences)
        send(timezone: identifier)
        onZoneChange()
    }

    func save(_ place: PersonPlace?) {
        guard !preferences.usesDeviceLocation else { return }
        send(timezone: nil, location: place.map(LocationChange.set) ?? .clear)
    }

    func useDeviceLocation(_ enabled: Bool) {
        preferences.usesDeviceLocation = enabled
        persist(preferences)
        if enabled {
            refresh(askForLocation: true)
        } else {
            locationTask?.cancel()
            send(timezone: nil, location: .clearDevice)
        }
    }

    /// Launch and system time-zone notifications are the two automatic refreshes.
    func refresh(askForLocation: Bool = false) {
        locationTask?.cancel()
        onZoneChange()
        guard preferences.usesDeviceLocation else {
            refreshZone()
            return
        }
        locationTask = Task { [weak self] in
            guard let self else { return }
            let place = await locate(askForLocation)
            guard !Task.isCancelled, preferences.usesDeviceLocation else { return }
            refreshZone(location: place.map(LocationChange.set),
                        message: place == nil ? "This Mac’s location is unavailable." : nil)
        }
    }

    func read() { send(timezone: nil) }

    private func refreshZone(location: LocationChange? = nil, message: String? = nil) {
        let timezone = preferences.followsMac || preferences.pinnedZone != nil ? zone : nil
        send(timezone: timezone, location: location, message: message)
    }

    private func send(timezone: String?, location: LocationChange? = nil, message: String? = nil) {
        let previous = updateTask
        updateTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let saved = if timezone != nil || location != nil {
                    try await update(timezone, location)
                } else {
                    try await load()
                }
                profile = saved
                status = message
                onZoneChange()
            } catch {
                status = "Couldn’t sync time zone and location with this workspace."
            }
        }
    }
}

extension HerdrClient {
    func personProfile() async throws -> WorkspacePersonProfile { try await get("/api/person-profile") }

    func updatePersonProfile(timezone: String?, location: HerdrPersonSettings.LocationChange?) async throws -> WorkspacePersonProfile {
        var fields: [String: Any] = [:]
        fields["timezone"] = timezone
        fields["location"] = location?.fields
        return try await post("/api/person-profile", fields)
    }

    func exportPersonProfile() async throws -> Data {
        let response = try await raw(request("/api/person-profile/export", method: "GET", body: nil))
        guard response.status == 200 else { throw BackendError.unavailable("Couldn’t export this profile.") }
        return response.data
    }
}
