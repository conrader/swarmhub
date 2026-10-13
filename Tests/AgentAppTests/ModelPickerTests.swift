import Foundation
import Testing
@testable import AgentApp

// P11: the Overview model picker mirrors what the bot's own Hermes profile reports. Synthetic data only
// (`ModelPickerTestSupport.swift`); URLProtocol mocks via `MockHermesProtocol`.

private func utc(_ text: String) -> Date { let f = ISO8601DateFormatter(); return f.date(from: text)! }
private func paths(_ host: String) -> [String] { MockHermesProtocol.recorded(host).map { "\($0.httpMethod ?? "GET") \($0.url!.path)\($0.url!.query.map { "?" + $0 } ?? "")" } }
private func assertNoSentinels(_ text: String, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for sentinel in catalogSentinels { #expect(!text.contains(sentinel), "\(what) leaks \(sentinel)", sourceLocation: sourceLocation) }
}
private final class TestClock: @unchecked Sendable { var now = utc("2026-10-13T10:00:00Z") }

// MARK: Parsing

@Test(arguments: CatalogShape.allCases) func catalogParsesOnlyAllowlistedKeys(shape: CatalogShape) {
    let options = HermesModelOptions.parse(catalogPayload(shape))
    #expect(options.model == "model-alpha"); #expect(options.provider == "lab-one")
    let lab = options.providers[1]
    #expect(options.providers[0].name == "Relay Router", "names are trimmed")
    #expect(lab.models == ["model-alpha", "model-beta", "model-gamma"], "strings and P3 objects; duplicates, blanks, >200 chars and control characters dropped")
    #expect(lab.aliases == ["lab-1"]); #expect(lab.isCurrent); #expect(options.defaultProvider?.slug == "lab-one")
    #expect(options.providers[3].unavailableModels == ["paid-a"])
    #expect(options.selectable.map(\.slug).starts(with: ["router", "lab-one", "preset-box", "lab-paid"]))
    let reflected = String(reflecting: options)
    assertNoSentinels(reflected, "String(reflecting:)")
    #expect(!((options as Any) is any Encodable)); #expect(!((lab as Any) is any Encodable))
    if shape == .v0217 {
        #expect(options.providers[0].limit == .models(["relay/model-2": Optional(utc("2026-10-13T12:30:00Z")), "relay/model-3": Optional<Date>.none] as [String: Date?]))
        #expect(options.providers[3].freeTierPending)
        #expect(options.providers.first { $0.slug == "box-local" }?.limit == .account(resetsAt: utc("2026-10-13T12:30:00Z")), "naive means UTC")
        #expect(options.providers.first { $0.slug == "lab-odd" }?.limit == nil, "an unrecognised shape is no state")
    } else {
        #expect(options.providers.allSatisfy { $0.limit == nil && !$0.freeTierPending })
    }
}

@Test func resetTimesParseOnlyPythonIsoformat() {
    #expect(HermesModelCatalog.date("2026-10-13T12:30:00.123456+00:00") == utc("2026-10-13T12:30:00Z"))
    #expect(HermesModelCatalog.date("2026-10-13T14:30:00+02:00") == utc("2026-10-13T12:30:00Z"))
    #expect(HermesModelCatalog.date("2026-10-13T12:30:00Z") == utc("2026-10-13T12:30:00Z"))
    #expect(HermesModelCatalog.date("2026-10-13T12:30:00") == utc("2026-10-13T12:30:00Z"))
    for bad in ["", "soon", "2026-10-13", "2026-10-13 12:30:00", "2026-10-13T12:30:00+0200", "1760358600"] { #expect(HermesModelCatalog.date(bad) == nil, "\(bad)") }
    #expect(HermesModelLimit.parse(["scope": "account", "resets_at": "tomorrow"]) == .account(resetsAt: nil))
    #expect(HermesModelLimit.parse(["scope": "models", "models": "all"]) == nil)
    #expect(HermesModelLimit.parse("account") == nil)
}

// MARK: Grouping and labels

@Test(arguments: CatalogShape.allCases) @MainActor func groupsFollowTheBoxDefaultFirstWithSkeletonsHidden(shape: CatalogShape) async {
    let (store, jarvis, rapper, _, _) = pickerStore(pickerServer(shape))
    await store.loadServerInfo(for: jarvis); await store.loadServerInfo(for: rapper)
    let picker = store.modelPicker(for: jarvis)
    #expect(picker.showsMenu && picker.canSwitch)
    let expected = ["lab-one", "router", "preset-box", "lab-paid"] + (shape == .v0217 ? ["box-local", "lab-odd"] : [])
    #expect(picker.groups.map(\.slug) == expected)
    #expect(picker.groups.map(\.title).prefix(3) == ["Lab One · default", "Relay Router", "Box Preset · preset"])
    if shape == .v0217 { #expect(picker.groups[4].title == "Box Local · runs on the box") }
    #expect(picker.hiddenCount == 2)
    #expect(picker.groups.map(\.usesSubmenu) == expected.map { $0 == "router" })
    #expect(picker.groups[1].items.map(\.model) == routerModels(20), "the server's order is kept")
    #expect(picker.groups[0].items.filter(\.isServerDefault).map(\.model) == ["model-alpha"])
    #expect(picker.caption == "Models provided by \(expected.count) providers on your Hermes box · default Lab One")
    #expect(picker.footer?.hasPrefix("Profile grok-jarvis · updated ") == true); #expect(picker.footer?.hasSuffix("2 providers not configured on the box") == true)
    #expect(picker.groups[0].items[1].accessibilityLabel == "model-beta, Lab One")
    #expect(picker.currentModel == "model-alpha"); #expect(picker.currentCaption == "Lab One · server default")
    #expect(store.modelPicker(for: rapper).caption == "Models provided by Lab Solo on your Hermes box")
    #expect(ModelPickerModel.tag(for: "user-config") == "custom endpoint"); #expect(ModelPickerModel.tag(for: "model-config") == "custom endpoint")
    #expect(ModelPickerModel.tag(for: "configured-current") == "sign-in needed"); #expect(ModelPickerModel.tag(for: "built-in") == nil)
}

@Test func checkmarkSitsUnderOneSupplier() {
    func supplier(_ slug: String, _ models: [String], current: Bool = false, aliases: [String] = []) -> HermesModelProvider {
        .init(slug: slug, name: slug.uppercased(), models: models, isCurrent: current, authenticated: true, source: "hermes", aliases: aliases)
    }
    let options = HermesModelOptions(providers: [supplier("one", ["m1", "shared"]), supplier("two", ["shared", "vendor/m2"]), supplier("three", ["shared", "m3"], current: true, aliases: ["tri"])], model: "m3", provider: "three")
    func checked(_ current: CurrentModel) -> [String] {
        var info = BotServerInfo(); info.modelOptions = .loaded(options); info.capabilities = .init(features: ["session_model_lock": true])
        return ModelPickerModel(info: info, current: current, sessionID: "s1", profile: "p").groups.flatMap { $0.items.filter(\.isChecked).map { "\($0.supplierSlug)/\($0.model)" } }
    }
    #expect(checked(.init(model: "shared", provider: "two", source: "chosen for this chat")) == ["two/shared"], "the lock's provider")
    #expect(checked(.init(model: "shared", provider: "tri", source: "chosen for this chat")) == ["three/shared"], "by alias")
    #expect(checked(.init(model: "shared", provider: nil, source: "this chat")) == ["three/shared"], "the default supplier lists it")
    #expect(checked(.init(model: "m2", provider: nil, source: "this chat")) == ["two/vendor/m2"], "the only supplier that lists it")
    let unlisted = ModelPickerModel(info: { var i = BotServerInfo(); i.modelOptions = .loaded(options); return i }(), current: .init(model: "elsewhere", provider: nil, source: "this chat"), sessionID: nil, profile: "p")
    #expect(unlisted.groups.allSatisfy { $0.items.allSatisfy { !$0.isChecked } }); #expect(unlisted.currentSupplier == ModelPickerModel.notListed)
    let twoNonDefault = HermesModelOptions(providers: [supplier("one", ["dup"]), supplier("two", ["dup"])], model: nil, provider: nil)
    var info = BotServerInfo(); info.modelOptions = .loaded(twoNonDefault)
    #expect(ModelPickerModel(info: info, current: .init(model: "dup", provider: nil, source: "this chat"), sessionID: nil, profile: "p").groups.allSatisfy { $0.items.allSatisfy { !$0.isChecked } })
}

// MARK: Unavailable items and reasons

@Test(arguments: CatalogShape.allCases) @MainActor func unavailableItemsStayVisibleWithTheirReason(shape: CatalogShape) async {
    let (store, jarvis, _, _, _) = pickerStore(pickerServer(shape))
    await store.loadServerInfo(for: jarvis)
    let picker = store.modelPicker(for: jarvis)
    #expect(picker.item(provider: "lab-paid", model: "paid-a")?.disabledReason == (shape == .v0217 ? "checking the plan" : "needs a paid plan"))
    #expect(picker.item(provider: "lab-paid", model: "free-b")?.isEnabled == true)
    if shape == .v0217 {
        #expect(picker.item(provider: "router", model: "relay/model-2")?.disabledReason?.hasPrefix("rate-limited until ") == true)
        #expect(picker.item(provider: "router", model: "relay/model-3")?.disabledReason == "rate-limited", "no time unless it parses")
        #expect(picker.item(provider: "box-local", model: "local-one")?.disabledReason?.hasPrefix("rate-limited until ") == true)
        #expect(picker.item(provider: "lab-odd", model: "odd-one")?.isEnabled == true)
    }
    #expect(picker.item(provider: "router", model: "relay/model-1")?.isEnabled == true)
}

@Test @MainActor func signedOutDefaultShowsItsSavedModelAndAWarning() async {
    let server = pickerServer(); server.set(catalog: catalogPayload(.v0217, defaultSignedOut: true), for: "grok-jarvis")
    let (store, jarvis, _, _, _) = pickerStore(server)
    await store.loadServerInfo(for: jarvis)
    let picker = store.modelPicker(for: jarvis)
    #expect(picker.groups[0].title == "Lab One · default · sign-in needed")
    #expect(picker.groups[0].items.map(\.model) == ["model-alpha"]); #expect(picker.groups[0].items[0].isEnabled == false)
    #expect(picker.groups[0].items[0].disabledReason == "sign-in needed on the box")
    #expect(picker.notes.contains { $0.isWarning && $0.text.contains("needs a new sign-in on the box") })
    #expect(picker.hiddenCount == 2, "a signed-out default is not a skeleton")
    assertNoSentinels(picker.notes.map(\.text).joined(), "notes")
}

@Test @MainActor func everyStateHasAReason() async {
    func picker(_ configure: (PickerServer) -> Void, session: String? = "s1", multiplexOff: Bool = false) async -> ModelPickerModel {
        let server = pickerServer(); configure(server)
        let (store, jarvis, _, _, _) = pickerStore(server, jarvisSession: session)
        if multiplexOff { store.prefixIgnoredHermesProfiles = ["grok-jarvis"] }
        await store.loadServerInfo(for: jarvis)
        return store.modelPicker(for: jarvis)
    }
    #expect(ModelPickerModel(info: nil, current: nil, sessionID: nil, profile: "p").notes.first?.text == "Loading the box's models…")
    let noMenu: [(String, ModelPickerModel)] = [
        ("capabilities 404", await picker { $0.set(capabilities: nil) }),
        ("model_options false", await picker { $0.set(capabilities: pickerCapabilities(modelOptions: false)) }),
        ("route 404", await picker { $0.set(status: 404, for: "/api/model/options") }),
        ("route 405", await picker { $0.set(status: 405, for: "/api/model/options") }),
        ("multiplex off", await picker({ _ in }, multiplexOff: true)),
    ]
    for (name, state) in noMenu {
        #expect(!state.showsMenu, "\(name)"); #expect(state.notes.count == 1 && state.notes[0].offersRetry == false, "\(name): \(state.notes)")
    }
    #expect(noMenu[4].1.notes[0].text.contains("multiplex_profiles"))
    for (status, suffix) in [(401, "/api/model/options"), (403, "/api/model/options"), (502, "/api/model/options"), (500, "/v1/capabilities")] {
        let state = await picker { $0.set(status: status, for: suffix) }
        #expect(!state.showsMenu && state.notes.first?.offersRetry == true, "\(status) \(suffix)")
        #expect(state.notes.first?.text.contains("jarvis-key-77") == false, "redacted")
    }
    let readOnly = await picker { $0.set(capabilities: pickerCapabilities(modelLock: false)) }
    #expect(readOnly.showsMenu && !readOnly.canSwitch && readOnly.groups.allSatisfy { $0.items.allSatisfy { !$0.isEnabled } })
    #expect(readOnly.switchBlockedReason?.hasPrefix("Read-only") == true)
    let noSession = await picker({ _ in }, session: nil)
    #expect(noSession.showsMenu && !noSession.canSwitch); #expect(noSession.notes.contains { $0.text.hasPrefix("Send a message first") })
    let nothing = await picker { $0.set(catalog: ["model": "x", "provider": "lab-two", "providers": [["slug": "lab-two", "name": "Lab Two", "models": [String](), "authenticated": false, "source": "canonical"]]], for: "grok-jarvis") }
    #expect(nothing.showsMenu && nothing.groups.isEmpty && nothing.hiddenCount == 1)
    #expect(nothing.notes.contains { $0.text.contains("Torvli never holds them") })
}

// MARK: Requests

@Test @MainActor func loadMakesP3sGetsIdenticallyOnBothShapes() async {
    var seen: [[String]] = []
    for shape in CatalogShape.allCases {
        let (store, jarvis, _, host, _) = pickerStore(pickerServer(shape))
        await store.loadServerInfo(for: jarvis)
        let requests = MockHermesProtocol.recorded(host)
        #expect(requests.allSatisfy { $0.url?.query == nil && $0.value(forHTTPHeaderField: "Authorization") == "Bearer jarvis-key-77" && $0.httpMethod == "GET" })
        seen.append(paths(host).sorted())
        for request in requests { assertNoSentinels(request.url!.absoluteString + "\(request.allHTTPHeaderFields ?? [:])", "request") }
    }
    #expect(seen[0] == ["GET /p/grok-jarvis/api/model/options", "GET /p/grok-jarvis/api/sessions/s1", "GET /p/grok-jarvis/v1/capabilities", "GET /p/grok-jarvis/v1/skills", "GET /p/grok-jarvis/v1/toolsets"])
    #expect(seen[0] == seen[1])
}

@Test(arguments: CatalogShape.allCases) @MainActor func switchSendsOnePostThenReadsBack(shape: CatalogShape) async throws {
    let (store, jarvis, _, host, url) = pickerStore(pickerServer(shape))
    await store.loadServerInfo(for: jarvis)
    let before = MockHermesProtocol.recorded(host).count
    await store.switchModel(for: jarvis, provider: "router", model: "relay/model-1")
    let after = Array(MockHermesProtocol.recorded(host).dropFirst(before))
    #expect(after.map { "\($0.httpMethod!) \($0.url!.path)" } == ["POST /p/grok-jarvis/api/sessions/s1/model", "GET /p/grok-jarvis/api/sessions/s1"])
    let body = try #require((try? JSONSerialization.jsonObject(with: pickerRequestBody(after[0]))) as? [String: Any])
    #expect(Set(body.keys) == ["model", "provider"]); #expect(body["provider"] as? String == "router")
    assertNoSentinels(String(decoding: pickerRequestBody(after[0]), as: UTF8.self), "lock body")
    #expect(store.currentModel(for: jarvis) == .init(model: "relay/model-1", provider: "router", source: "chosen for this chat"))
    let picker = store.modelPicker(for: jarvis)
    #expect(picker.groups.flatMap { $0.items.filter(\.isChecked) }.map(\.id) == ["router\nrelay/model-1"])
    #expect(picker.currentCaption == "Relay Router · chosen for this chat")
    #expect(store.botInfo.info(for: jarvis.id)?.modelError == nil)
    assertNoSentinels(String(decoding: try JSONEncoder().encode(jarvis), as: UTF8.self), "Bot JSON")
    assertNoSentinels((try? String(contentsOf: url, encoding: .utf8)) ?? "", "store.json")
    assertNoSentinels(HeadlessSnapshot.overviewSummary(store: store, bot: jarvis), "overviewSummary")
    assertNoSentinels(store.modelMenuSummary(for: jarvis), "headless line")
}

@Test @MainActor func refusedSwitchesSendNothing() async {
    let server = pickerServer(.v0205)
    let (store, jarvis, _, host, _) = pickerStore(server)
    await store.loadServerInfo(for: jarvis)
    for (provider, model) in [("router", "model-alpha"), ("lab-paid", "paid-a"), ("nobody", "model-alpha"), ("lab-one", "made-up")] {
        await store.switchModel(for: jarvis, provider: provider, model: model)
        #expect(store.botInfo.info(for: jarvis.id)?.modelError?.hasPrefix("The box does not offer \(model)") == true, "\(provider)/\(model)")
    }
    server.set(status: 500, for: "/api/model/options")
    await store.loadServerInfo(for: jarvis, force: true)
    await store.switchModel(for: jarvis, provider: "lab-one", model: "model-beta")
    #expect(store.botInfo.info(for: jarvis.id)?.modelError?.hasPrefix("The box does not offer") == true, "no list loaded")
    #expect(!MockHermesProtocol.recorded(host).contains { $0.httpMethod == "POST" }); #expect(jarvis.hermesModelLock == nil)
}

@Test @MainActor func switchErrorsAreRedacted() async {
    let server = pickerServer()
    let (store, jarvis, _, _, _) = pickerStore(server)
    await store.loadServerInfo(for: jarvis)
    server.set(status: 500, for: "/api/sessions/s1/model")
    await store.switchModel(for: jarvis, provider: "lab-one", model: "model-beta")
    let error = store.botInfo.info(for: jarvis.id)?.modelError ?? ""
    #expect(error.contains("[key]")); #expect(!error.contains("jarvis-key-77")); #expect(jarvis.hermesModelLock == nil)
    #expect(ModelPickerModel.buttonHelp.contains("no way to unpin"))
}

// MARK: Current model

@Test @MainActor func boxBeatsAStaleLockAndFailedReadsKeepTheLastGoodValue() async {
    let server = pickerServer()
    let (store, jarvis, _, _, _) = pickerStore(server)
    await store.loadServerInfo(for: jarvis)
    await store.switchModel(for: jarvis, provider: "lab-one", model: "model-beta")
    #expect(store.currentModel(for: jarvis)?.source == "chosen for this chat")
    server.set(sessionModel: "model-gamma", profile: "grok-jarvis", session: "s1")   // another client switched it
    await store.loadServerInfo(for: jarvis, force: true)
    #expect(store.currentModel(for: jarvis) == .init(model: "model-gamma", provider: nil, source: "this chat"))
    #expect(store.modelPicker(for: jarvis).item(provider: "lab-one", model: "model-gamma")?.isChecked == true)
    server.set(status: 503, for: "/api/sessions/s1")
    await store.loadServerInfo(for: jarvis, force: true)
    #expect(store.currentModel(for: jarvis)?.model == "model-gamma", "a failed session read keeps the last good value")
    jarvis.hermesSessionID = "s2"
    #expect(store.currentModel(for: jarvis)?.source == "server default", "a model read for another session is ignored")
    server.set(sessionModel: "elsewhere-9", profile: "grok-jarvis", session: "s2")
    await store.loadServerInfo(for: jarvis)
    #expect(store.modelPicker(for: jarvis).currentSupplier == ModelPickerModel.notListed)
}

@Test @MainActor func acceptedLockShowsTheNewModelEvenWhenTheReadBackFails() async {
    let server = pickerServer()
    let (store, jarvis, _, _, _) = pickerStore(server)
    server.set(sessionModel: "model-alpha", profile: "grok-jarvis", session: "s1")
    await store.loadServerInfo(for: jarvis)
    server.set(status: 500, for: "/api/sessions/s1")
    await store.switchModel(for: jarvis, provider: "lab-one", model: "model-beta")
    #expect(store.botInfo.info(for: jarvis.id)?.sessionModel == "model-beta")
    #expect(store.currentModel(for: jarvis)?.model == "model-beta"); #expect(store.botInfo.info(for: jarvis.id)?.modelError == nil)
}

// MARK: Live, per profile

@Test @MainActor func twoProfilesNeverMix() async {
    let (store, jarvis, rapper, host, _) = pickerStore(pickerServer(.v0217))
    await store.loadServerInfo(for: jarvis); await store.loadServerInfo(for: rapper)
    #expect(store.modelPicker(for: rapper).groups.map(\.slug) == ["lab-solo"]); #expect(store.modelPicker(for: rapper).profile == "grok-rapper")
    #expect(!store.modelPicker(for: jarvis).groups.contains { $0.slug == "lab-solo" })
    #expect(store.currentModel(for: rapper)?.model == "solo-model")
    for request in MockHermesProtocol.recorded(host) {
        let profile = request.url!.path.split(separator: "/")[1]
        #expect(request.value(forHTTPHeaderField: "Authorization") == (profile == "grok-rapper" ? "Bearer rapper-key-88" : "Bearer jarvis-key-77"))
    }
    await store.switchModel(for: rapper, provider: "lab-one", model: "model-alpha")
    #expect(!MockHermesProtocol.recorded(host).contains { $0.httpMethod == "POST" }, "Jarvis's suppliers are not Rapper's")
}

@Test @MainActor func reloadsFollowAgeScopeSessionAndFailure() async {
    let server = pickerServer()
    let (store, jarvis, _, host, _) = pickerStore(server)
    let clock = TestClock(); store.botInfo.now = { clock.now }
    func loads() -> Int { MockHermesProtocol.recorded(host).filter { $0.url!.path.hasSuffix("/v1/capabilities") }.count }
    await store.loadServerInfo(for: jarvis); #expect(loads() == 1)
    clock.now += 299; await store.loadServerInfo(for: jarvis); #expect(loads() == 1, "fresh")
    clock.now += 1; await store.loadServerInfo(for: jarvis); #expect(loads() == 2, "300 s old")
    jarvis.hermesSessionID = "s9"; await store.loadServerInfo(for: jarvis); #expect(loads() == 3, "the session id changed")
    jarvis.hermesProfile = "grok-rapper"; await store.loadServerInfo(for: jarvis); #expect(loads() == 4, "another scope")
    #expect(store.modelPicker(for: jarvis).groups.map(\.slug) == ["lab-solo"])
    jarvis.hermesProfile = "grok-jarvis"; jarvis.hermesSessionID = "s1"
    server.set(status: 500, for: "/api/model/options")
    await store.loadServerInfo(for: jarvis); #expect(loads() == 5)
    server.set(status: nil, for: "/api/model/options")
    await store.loadServerInfo(for: jarvis); #expect(loads() == 6, "failed last time")
    await store.loadServerInfo(for: jarvis); #expect(loads() == 6)
    await store.loadServerInfo(for: jarvis, force: true); #expect(loads() == 7, "the reload button forces")
}

@Test @MainActor func reloadFinishingDuringASwitchKeepsItsState() async throws {
    // A switch in flight, as `switchModel` drives the cache: begun, POST not yet answered. A blocking mock would stall
    // URLProtocol's shared loader thread, so the reload runs between the cache steps instead.
    let server = pickerServer()
    let (store, jarvis, _, _, _) = pickerStore(server)
    server.set(sessionModel: "model-alpha", profile: "grok-jarvis", session: "s1")
    await store.loadServerInfo(for: jarvis)
    store.botInfo.beginSwitch(botID: jarvis.id)
    server.set(sessionModel: "model-beta", profile: "grok-jarvis", session: "s1")
    await store.loadServerInfo(for: jarvis, force: true)
    var info = try #require(store.botInfo.info(for: jarvis.id))
    #expect(info.isSwitchingModel, "the reload merged into the entry"); #expect(store.modelPicker(for: jarvis).isSwitching)
    #expect(info.sessionModel == "model-alpha", "a reload overlapping a switch leaves the session model to the switch")
    #expect(info.modelOptions.value != nil && !info.isRefreshing)
    store.botInfo.setSessionModel(botID: jarvis.id, sessionID: "s1", model: "model-beta"); store.botInfo.finishSwitch(botID: jarvis.id, error: nil)
    info = try #require(store.botInfo.info(for: jarvis.id))
    #expect(!info.isSwitchingModel && info.modelError == nil && info.sessionModel == "model-beta")
    #expect(store.currentModel(for: jarvis)?.model == "model-beta")
}

// MARK: Headless line and sources

@Test @MainActor func headlessLineNamesSuppliersInMenuOrder() async {
    let (store, jarvis, rapper, _, _) = pickerStore(pickerServer(.v0205), jarvisSession: nil)
    await store.loadServerInfo(for: jarvis); await store.loadServerInfo(for: rapper)
    #expect(store.modelMenuSummary(for: jarvis) == "Jarvis: model menu Lab One [default] 3 | Relay Router 20 submenu | Box Preset [preset] 1 | Lab Paid 2; hidden 2; profile grok-jarvis; switching off (Send a message first; the model is chosen per chat.)")
    #expect(store.modelMenuSummary(for: rapper) == "Rapper: model menu Lab Solo [default] 2; hidden 0; profile grok-rapper; switching on")
    #expect(HeadlessSnapshot.overviewSummary(store: store, bot: rapper) == "Rapper: Overview skills 1, toolsets 1, model solo-model (server default), picker on")
    store.prefixIgnoredHermesProfiles = ["grok-rapper"]; await store.loadServerInfo(for: rapper)
    #expect(store.modelMenuSummary(for: rapper).hasPrefix("Rapper: model menu none (grok-rapper: Server ignored the profile prefix"))
}

@Test func fixtureNamesNeverReachSources() throws {
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(files.count > 50)
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for name in catalogFixtureNames + catalogSentinels { #expect(!text.contains(name), "\(file.lastPathComponent) contains \(name)") }
    }
}
