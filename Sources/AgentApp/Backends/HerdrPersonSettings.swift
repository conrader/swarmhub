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
    var followSource: String?
}

struct PersonSettingsPreferences: Codable {
    var followMacChoice: Bool?
    var usesDeviceLocation = false

    var followsMac: Bool { followMacChoice == true }

    static func restored(from data: Data?) -> Self {
        guard let data, var saved = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        // The old true default did not distinguish an explicit opt-in from a launch.
        // Preserve the old explicit opt-out and keep the device's location consent.
        struct Legacy: Decodable { let followsMac: Bool? }
        if saved.followMacChoice == nil, (try? JSONDecoder().decode(Legacy.self, from: data))?.followsMac == false {
            saved.followMacChoice = false
        }
        return saved
    }
}

@MainActor final class HerdrPersonSettings: ObservableObject {
    enum ZoneChange: Equatable {
        case manual(String), firstMac(String), enable(String), sync(String), disable

        func fields(device: String) -> [String: Any] {
            let kind: String
            let timezone: String?
            switch self {
            case .manual(let value): return ["timezone": value]
            case .firstMac(let value): (kind, timezone) = ("default", value)
            case .enable(let value): (kind, timezone) = ("enable", value)
            case .sync(let value): (kind, timezone) = ("sync", value)
            case .disable: (kind, timezone) = ("disable", nil)
            }
            var follow = ["kind": kind, "device": device]
            follow["timezone"] = timezone
            return ["follow": follow]
        }
    }

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
    private let update: (ZoneChange?, LocationChange?) async throws -> WorkspacePersonProfile
    private let locate: (Bool) async -> PersonPlace?
    private let macZone: () -> String
    private let deviceID: () -> String
    private let persist: (PersonSettingsPreferences) -> Void
    private let onZoneChange: () -> Void
    private var zoneChoiceRevision = 0

    var zone: String { preferences.followsMac ? macZone() : profile.timezone ?? macZone() }
    var displayZone: TimeZone { TimeZone(identifier: zone) ?? .autoupdatingCurrent }

    init(preferences: PersonSettingsPreferences,
         load: @escaping () async throws -> WorkspacePersonProfile,
         update: @escaping (ZoneChange?, LocationChange?) async throws -> WorkspacePersonProfile,
         locate: @escaping (Bool) async -> PersonPlace?,
         macZone: @escaping () -> String = { TimeZone.autoupdatingCurrent.identifier },
         deviceID: @escaping () -> String,
         persist: @escaping (PersonSettingsPreferences) -> Void,
         onZoneChange: @escaping () -> Void = {}) {
        self.preferences = preferences
        self.load = load
        self.update = update
        self.locate = locate
        self.macZone = macZone
        self.deviceID = deviceID
        self.persist = persist
        self.onZoneChange = onZoneChange
    }

    func followMac(_ follows: Bool) {
        zoneChoiceRevision += 1
        preferences.followMacChoice = follows
        persist(preferences)
        send(zone: follows ? .enable(macZone()) : .disable)
        onZoneChange()
    }

    func pin(_ identifier: String) {
        guard !preferences.followsMac, TimeZone(identifier: identifier) != nil else { return }
        zoneChoiceRevision += 1
        preferences.followMacChoice = false
        persist(preferences)
        send(zone: .manual(identifier))
        onZoneChange()
    }

    func save(_ place: PersonPlace?) {
        guard !preferences.usesDeviceLocation else { return }
        send(location: place.map(LocationChange.set) ?? .clear)
    }

    func useDeviceLocation(_ enabled: Bool) {
        preferences.usesDeviceLocation = enabled
        persist(preferences)
        if enabled {
            refresh(askForLocation: true)
        } else {
            locationTask?.cancel()
            send(location: .clearDevice)
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

    func read() { send() }

    private func refreshZone(location: LocationChange? = nil, message: String? = nil) {
        let change: ZoneChange = switch preferences.followMacChoice {
        case nil: .firstMac(macZone())
        case true?: .sync(macZone())
        case false?: .disable
        }
        send(zone: change, location: location, message: message)
    }

    private func send(zone: ZoneChange? = nil, location: LocationChange? = nil, message: String? = nil) {
        let previous = updateTask
        let revision = zoneChoiceRevision
        updateTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let saved = if zone != nil || location != nil {
                    try await update(zone, location)
                } else {
                    try await load()
                }
                profile = saved
                if revision == zoneChoiceRevision,
                   preferences.followsMac || (preferences.followMacChoice == nil && zone != nil) {
                    let follows = saved.followSource == deviceID()
                    if preferences.followMacChoice != follows {
                        preferences.followMacChoice = follows
                        persist(preferences)
                    }
                }
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

    func updatePersonProfile(zone: HerdrPersonSettings.ZoneChange?, device: String, location: HerdrPersonSettings.LocationChange?) async throws -> WorkspacePersonProfile {
        var fields = zone?.fields(device: device) ?? [:]
        fields["location"] = location?.fields
        return try await post("/api/person-profile", fields)
    }

    func exportPersonProfile() async throws -> Data {
        let response = try await raw(request("/api/person-profile/export", method: "GET", body: nil))
        guard response.status == 200 else { throw BackendError.unavailable("Couldn’t export this profile.") }
        return response.data
    }
}
