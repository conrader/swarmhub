import Foundation
import Testing
@testable import AgentApp

@MainActor private final class PersonSettingsFixture {
    var macZone = "Europe/Warsaw"
    var profile = WorkspacePersonProfile()
    var updates: [(String?, HerdrPersonSettings.LocationChange?)] = []
    var requests: [Bool] = []
    var saved: PersonSettingsPreferences?
    var locate: () async -> PersonPlace? = { nil }

    func model(_ preferences: PersonSettingsPreferences = .init()) -> HerdrPersonSettings {
        HerdrPersonSettings(preferences: preferences, load: { self.profile }, update: { zone, change in
            self.updates.append((zone, change))
            if let zone { self.profile.timezone = zone }
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
        }, macZone: { self.macZone }, persist: { self.saved = $0 })
    }
}

@MainActor @Test func personSettingsFollowsTheMacByDefaultAndKeepsAPinnedZone() async {
    let fixture = PersonSettingsFixture()
    let model = fixture.model()
    #expect(model.preferences.followsMac)
    #expect(!model.preferences.usesDeviceLocation)
    model.refresh()
    await model.updateTask?.value
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
    #expect(fixture.saved?.pinnedZone == "Europe/Warsaw")
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
    #expect(fixture.updates.last?.0 == "Asia/Bangkok")
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
