import Foundation
import Testing
@testable import AgentApp

@MainActor private final class PersonSettingsFixture {
    var macZone = "Europe/Warsaw"
    var profile = WorkspacePersonProfile()
    var updates: [(HerdrPersonSettings.ZoneChange?, HerdrPersonSettings.LocationChange?)] = []
    var requests: [Bool] = []
    var saved: PersonSettingsPreferences?
    var locate: () async -> PersonPlace? = { nil }
    private let device = "a"

    func model(_ preferences: PersonSettingsPreferences = .init()) -> HerdrPersonSettings {
        HerdrPersonSettings(preferences: preferences, load: { self.profile }, update: { zone, change in
            self.updates.append((zone, change))
            switch zone {
            case .firstMac(let value) where self.profile.followSource == nil || self.profile.followSource == self.device,
                 .enable(let value):
                self.profile.followSource = self.device
                self.profile.timezone = value
            case .sync(let value) where self.profile.followSource == self.device:
                self.profile.timezone = value
            case .disable where self.profile.followSource == self.device:
                self.profile.followSource = nil
            case .manual(let value):
                self.profile.followSource = nil
                self.profile.timezone = value
            default: break
            }
            switch change {
            case .set(let place): self.profile.location = place
            case .clear: self.profile.location = nil
            case .clearDevice where self.profile.location?.source == .device: self.profile.location = nil
            default: break
            }
            return self.profile
        }, locate: { requestedPermission in
            self.requests.append(requestedPermission)
            return await self.locate()
        }, macZone: { self.macZone }, deviceID: { self.device }, persist: { self.saved = $0 })
    }
}

@MainActor @Test func personSettingsFollowsTheMacByDefaultAndKeepsAPinnedZone() async {
    let fixture = PersonSettingsFixture()
    let model = fixture.model()
    #expect(model.preferences.followMacChoice == nil)
    #expect(!model.preferences.usesDeviceLocation)
    model.refresh()
    await model.updateTask?.value
    #expect(model.preferences.followsMac)
    #expect(fixture.saved?.followMacChoice == true)
    #expect(fixture.profile.timezone == "Europe/Warsaw")
    fixture.macZone = "Asia/Bangkok"
    model.refresh()
    await model.updateTask?.value
    #expect(model.displayZone.identifier == "Asia/Bangkok")
    #expect(fixture.profile.timezone == "Asia/Bangkok")
    model.followMac(false)
    model.pin("Europe/Warsaw")
    model.pin("Mars/Olympus")
    model.refresh()
    await model.updateTask?.value
    #expect(fixture.profile.timezone == "Europe/Warsaw")
    #expect(fixture.saved?.followsMac == false)
    #expect(fixture.updates.map(\.0).suffix(3) == [.disable, .manual("Europe/Warsaw"), .disable])
    #expect(fixture.requests.isEmpty)
}

@MainActor @Test func personSettingsRequestsDeviceLocationOnlyAfterOptIn() async {
    let fixture = PersonSettingsFixture()
    let model = fixture.model()
    let manual = PersonPlace.manual(city: " Warsaw ", region: " ", country: "Poland")
    model.save(manual)
    await model.updateTask?.value
    #expect(fixture.profile.location?.label == "Warsaw, Poland")
    #expect(fixture.profile.location?.source == .manual)
    #expect(fixture.requests.isEmpty)
    fixture.locate = { PersonPlace(city: "Bangkok", region: nil, country: "Thailand", source: .device) }
    fixture.macZone = "Asia/Bangkok"
    model.useDeviceLocation(true)
    await model.locationTask?.value
    await model.updateTask?.value
    #expect(fixture.requests == [true])
    #expect(fixture.updates.last?.0 == .firstMac("Asia/Bangkok"))
    #expect(fixture.profile.location?.source == .device)
    model.refresh()
    await model.locationTask?.value
    await model.updateTask?.value
    #expect(fixture.requests == [true, false])
    model.useDeviceLocation(false)
    await model.updateTask?.value
    #expect(fixture.profile.location == nil)
    #expect(fixture.saved?.usesDeviceLocation == false)
}

@MainActor @Test func aSecondMacDefaultsOffAndCanTakeOverOnlyWhenEnabled() async {
    let fixture = PersonSettingsFixture()
    fixture.profile.followSource = "other"
    fixture.profile.timezone = "Asia/Bangkok"
    let model = fixture.model()
    model.refresh()
    await model.updateTask?.value
    #expect(fixture.saved?.followMacChoice == false)
    #expect(model.displayZone.identifier == "Asia/Bangkok")
    fixture.macZone = "UTC"
    model.refresh()
    await model.updateTask?.value
    #expect(fixture.profile.timezone == "Asia/Bangkok")
    model.followMac(true)
    await model.updateTask?.value
    #expect(fixture.updates.last?.0 == .enable("UTC"))
    #expect(fixture.profile.timezone == "UTC")
    fixture.profile.followSource = "other"
    fixture.profile.timezone = "Asia/Bangkok"
    model.refresh()
    await model.updateTask?.value
    #expect(fixture.saved?.followMacChoice == false)
    #expect(model.displayZone.identifier == "Asia/Bangkok")
}

@MainActor @Test func systemTimeZoneNotificationRefreshesTheWorkspaceThroughTheInjectedCenter() async throws {
    let fixture = PersonSettingsFixture()
    let store = AppStore(
        storeURL: FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-\(UUID())/store.json"),
        autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults()
    )
    store.launchWorkEnabled = true
    _ = store.personSettings(for: store.herdrServers[0])
    let key = try #require(store.personSettingsModels.keys.first)
    let model = fixture.model()
    store.personSettingsModels[key] = model
    let center = NotificationCenter()
    store.startPersonSettings(notificationCenter: center)
    await model.updateTask?.value
    #expect(fixture.profile.timezone == "Europe/Warsaw")

    fixture.macZone = "Asia/Bangkok"
    center.post(name: .NSSystemTimeZoneDidChange, object: nil)
    try await grokWait { fixture.updates.count == 2 }
    await model.updateTask?.value
    #expect(fixture.updates.last?.0 == .sync("Asia/Bangkok"))
    #expect(fixture.profile.timezone == "Asia/Bangkok")
}

@MainActor @Test func turningOffMacLocationDiscardsAResultStillInFlight() async {
    let fixture = PersonSettingsFixture()
    let model = fixture.model()
    var finish: CheckedContinuation<PersonPlace?, Never>?
    fixture.locate = { await withCheckedContinuation { finish = $0 } }
    model.useDeviceLocation(true)
    while finish == nil { await Task.yield() }
    model.useDeviceLocation(false)
    finish?.resume(returning: PersonPlace(city: "Bangkok", region: nil, country: "Thailand", source: .device))
    await model.locationTask?.value
    await model.updateTask?.value
    #expect(fixture.updates.count == 1)
    #expect(fixture.updates.first?.1 == .clearDevice)
    #expect(fixture.profile.location == nil)
}
