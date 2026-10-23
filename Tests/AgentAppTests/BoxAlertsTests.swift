import AppKit
import CryptoKit
import Foundation
import Testing
@testable import AgentApp

// Off-app alerts: the settings sealed to the box's key (the same vector as sim/test_alerts.py), the one command shape
// the Hermes stream keeps, the panel answer, the store's save/test flow and the presence lease that stops double alerts.

private let vectorBoxPublic = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw"
private let vector = "v1.WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpntbpN003rAeWCpygn1YvbvZkWLEAaYz6LERav7U6ckCQmMdzCxqaMoCphvq5xicsC4"
    + "VohICnqnsTTcffP5PbwE0aUd3EgWIcEjoisa7UbE"
private func boxPrivate() -> Curve25519.KeyAgreement.PrivateKey {
    try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data((1...32).map { UInt8($0) }))
}

/// The box's side (`swarm_alerts_seal.open_sealed`), for checking what the app sealed.
private func openSealed(_ blob: String, with key: Curve25519.KeyAgreement.PrivateKey = boxPrivate()) throws -> Data {
    let raw = try #require(AlertSeal.unpadded(String(blob.dropFirst(3))))
    let theirs = raw.prefix(32), body = raw.dropFirst(32).dropLast(16), tag = raw.suffix(16)
    let shared = try key.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: theirs))
    let keys = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(theirs) + key.publicKey.rawRepresentation,
                                              sharedInfo: AlertSeal.info, outputByteCount: 64).withUnsafeBytes { Data($0) }
    let check = Data(HMAC<SHA256>.authenticationCode(for: Data(theirs) + Data(body), using: SymmetricKey(data: keys.suffix(32)))).prefix(16)
    #expect(check == Data(tag))
    var stream = Data(), counter: UInt64 = 0
    while stream.count < body.count {
        stream += Data(HMAC<SHA256>.authenticationCode(for: withUnsafeBytes(of: counter.bigEndian) { Data($0) }, using: SymmetricKey(data: keys.prefix(32))))
        counter += 1
    }
    return Data(zip(Data(body), stream).map { $0 ^ $1 })
}

func alertsPanelJSON(action: String, boxKey: String = vectorBoxPublic, configured: Bool = false, enabled: Bool = false, running: Bool = false,
                     result: [String: Any]? = nil, revision: Int? = nil) -> String {
    var config: [String: Any] = ["configured": configured, "enabled": enabled, "window": true, "sinks": configured ? ["ntfy"] : []]
    if let revision { config["revision"] = revision }
    let object: [String: Any] = [
        "schema": "swarmhub/alerts/1", "action": action, "result": result ?? NSNull(), "box_key": boxKey,
        "config": config,
        "service": ["manager": "systemd", "installed": running, "service": running ? "active" : "not installed", "running": running,
                    "detail": running ? "Running." : "The alert service is not installed on this box.", "logs": "journalctl --user -u swarmhub-alerts.service",
                    "heartbeat": NSNull(), "last_error": NSNull(), "last_error_at": NSNull(), "last_sent_at": running ? 1_800_000_000 : NSNull(),
                    "presence_until": NSNull(), "pending": 0]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test func theSealMatchesTheBoxsVector() throws {
    #expect(boxPrivate().publicKey.rawRepresentation.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == vectorBoxPublic)
    let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data((33...64).map { UInt8($0) }))
    let plain = Data(#"{"v":1,"enabled":true,"ntfy":{"url":"https://ntfy.example/t"}}"#.utf8)
    #expect(try AlertSeal.seal(plain, to: vectorBoxPublic, ephemeral: ephemeral) == vector)
    #expect(try openSealed(vector) == plain)
    #expect(throws: BoxAlertsError.noBoxKey) { try AlertSeal.seal(plain, to: "short") }
}

@Test func onlyTheAlertsCommandShapesAreKeptForPairing() {
    #expect(AlertsCommand.arguments(.status) == ["alerts", "panel", "status"])
    #expect(AlertsCommand.arguments(.configure(vector)) == ["alerts", "panel", "configure", vector])
    #expect(AlertsCommand.arguments(.configure("v1.short")) == nil && AlertsCommand.arguments(.configure(vector + ";id")) == nil)
    for profile in ["default", "grok-jarvis"] {
        let script = SkillLibrary.installPath("swarmhub-messages", profile: profile) + "/scripts/swarmctl"
        for action in [BoxAlertsAction.status, .test, .install, .uninstall, .configure(vector)] {
            let line = WebhookCommand.line(script: script, arguments: AlertsCommand.arguments(action)!)
            #expect(AlertsCommand.matches(line), "\(line)")
            #expect(HermesBackend.webhookPanelCommand(["command": line]) == line)
        }
        #expect(!AlertsCommand.matches(WebhookCommand.line(script: script, arguments: ["alerts", "panel", "status;", "id"])))
        #expect(!AlertsCommand.matches(WebhookCommand.line(script: script, arguments: ["alerts", "run"])))
    }
}

@Test func thePanelAnswerDecodesAndARefusalKeepsTheBoxsReason() throws {
    let panel = try BoxAlertsPanel.decode("noise\n" + alertsPanelJSON(action: "status", configured: true, enabled: true, running: true))
    #expect(panel.boxKey == vectorBoxPublic && panel.config.sinks == ["ntfy"] && panel.service.running && panel.service.lastSentAt == 1_800_000_000)
    let wrapped = String(decoding: try JSONSerialization.data(withJSONObject: ["output": "swarmctl: sealed alert settings are not readable\n", "exit_code": 64]), as: UTF8.self)
    #expect(throws: BoxAlertsError.refused("sealed alert settings are not readable")) { try BoxAlertsPanel.decode(wrapped) }
    #expect(throws: BoxAlertsError.unreadable) { try BoxAlertsPanel.decode("hello") }
}

@Test func theBoxJSONCarriesASecretOnlyWhenOneIsSet() throws {
    var settings = AlertSettings()
    settings.ntfyURL = "https://ntfy.sh/topic"
    let plain = try #require(JSONSerialization.jsonObject(with: settings.boxJSON(ntfyToken: "", emailPassword: "")) as? [String: Any])
    #expect(plain["v"] as? Int == 1 && (plain["ntfy"] as? [String: Any])?["token"] == nil && plain["email"] == nil)
    settings.emailOn = true; settings.emailHost = "smtp.example"; settings.emailFrom = "a@example"; settings.emailTo = "b@example"
    let full = try #require(JSONSerialization.jsonObject(with: settings.boxJSON(ntfyToken: "tk", emailPassword: "pw")) as? [String: Any])
    #expect((full["ntfy"] as? [String: Any])?["token"] as? String == "tk")
    #expect((full["email"] as? [String: Any])?["password"] as? String == "pw" && (full["email"] as? [String: Any])?["security"] as? String == "starttls")
    #expect(AlertsCopy.all.count == Set(AlertsCopy.all).count && AlertsCopy.all.allSatisfy { !$0.isEmpty })
}

// MARK: Store

@MainActor private final class FakeAlertsBox { var calls: [[String]] = [] }

@MainActor private func alertsStore(answer: @escaping @MainActor ([String]) throws -> String) -> (AppStore, String, FakeAlertsBox, InMemoryKeyStore) {
    let keys = InMemoryKeyStore([:])
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: isolatedDefaults())
    store.boxAlertsOn = true  // rel066: switched off in the release; these tests are of the alerts themselves.
    let bot = Bot(name: "Reporter", backend: .hermes, hermesProfile: "reporter")
    bot.hermesBaseURL = "https://box.example.invalid/v1"
    store.bots = [bot]
    let box = FakeAlertsBox()
    store.alertsControl = { _, arguments in box.calls.append(arguments); return try answer(arguments) }
    return (store, store.connection(of: bot), box, keys)
}

@Test @MainActor func savingSealsTheSecretsToTheBoxKeyAndKeepsThemInTheKeychainOnly() async throws {
    let (store, target, box, keys) = alertsStore { args in
        args[2] == "configure" ? alertsPanelJSON(action: "configure", configured: true, enabled: true, running: true, result: ["saved": true, "manager": "systemd"])
            : alertsPanelJSON(action: args[2])
    }
    #expect(store.hermesConnections.map(\.target) == [target])
    var settings = AlertSettings()
    settings.ntfyURL = "https://ntfy.sh/konrad-alerts"
    await store.saveAlerts(settings, ntfyToken: "tk_secret_123", emailPassword: "", on: target)
    #expect(box.calls.map { Array($0.prefix(3)) } == [["alerts", "panel", "status"], ["alerts", "panel", "configure"]], "the box key is read first")
    let blob = try #require(box.calls.last?.last)
    #expect(!box.calls.joined().joined().contains("tk_secret_123"))
    let sealed = try #require(JSONSerialization.jsonObject(with: try openSealed(blob)) as? [String: Any])
    #expect((sealed["ntfy"] as? [String: Any])?["token"] as? String == "tk_secret_123" && sealed["enabled"] as? Bool == true)
    #expect(keys.key(for: AppStore.alertSecretAccount("ntfy", target: target)) == "tk_secret_123")
    #expect(store.defaults.dictionaryRepresentation().values.allSatisfy { !String(describing: $0).contains("tk_secret_123") })
    #expect(store.alertSettings(for: target).ntfyURL == "https://ntfy.sh/konrad-alerts" && store.alertServers == [target])
    let state = store.boxAlerts.state(for: target)
    #expect(state.notice == AlertsCopy.saved && state.error == nil && state.panel?.service.running == true && state.busy == nil)

    // The key is known now: saving again is one call; turning off seals enabled=false and drops the lease.
    box.calls = []
    await store.turnOffAlerts(on: target)
    #expect(box.calls.count == 1)
    #expect((try JSONSerialization.jsonObject(with: try openSealed(try #require(box.calls.last?.last))) as? [String: Any])?["enabled"] as? Bool == false)
}

/// recsfix1 (#14): the sealed settings name the profiles this Mac connected on that server, and no other: the box alerts
/// for those only.
@Test @MainActor func theSealedSettingsListOnlyTheProfilesConnectedOnThatServer() async throws {
    let (store, target, box, _) = alertsStore { args in
        args[2] == "configure" ? alertsPanelJSON(action: "configure", configured: true, enabled: true, running: true, result: ["saved": true])
            : alertsPanelJSON(action: args[2])
    }
    func hermesBot(_ name: String, profile: String, url: String = "https://box.example.invalid/v1") -> Bot {
        let bot = Bot(name: name, backend: .hermes, hermesProfile: profile); bot.hermesBaseURL = url; return bot
    }
    let archived = hermesBot("Old", profile: "old-archive"), retired = hermesBot("Gone", profile: "gone")
    archived.archivedMembers = ["Old"]; retired.retiredOnBox = true
    store.bots += [hermesBot("Jarvis", profile: "grok-jarvis"), hermesBot("Twin", profile: "grok-jarvis"), archived, retired,
                   hermesBot("Elsewhere", profile: "cfo", url: "https://other.example.invalid/v1")]
    var settings = AlertSettings(); settings.ntfyURL = "https://ntfy.sh/konrad-alerts"
    await store.saveAlerts(settings, ntfyToken: "", emailPassword: "", on: target)
    let blob = try #require(box.calls.last?.last)
    let sealed = try #require(JSONSerialization.jsonObject(with: try openSealed(blob)) as? [String: Any])
    #expect(sealed["profiles"] as? [String] == ["grok-jarvis", "reporter"])
}

/// The profiles in the last settings the app sealed for the box, and the ntfy token they carried.
@MainActor private func lastSealed(_ box: FakeAlertsBox) throws -> (profiles: [String]?, token: String?) {
    let blob = try #require(box.calls.last { $0.count > 3 && $0[2] == "configure" }?.last)
    let sealed = try #require(JSONSerialization.jsonObject(with: try openSealed(blob)) as? [String: Any])
    return (sealed["profiles"] as? [String], (sealed["ntfy"] as? [String: Any])?["token"] as? String)
}

@MainActor private final class Refusing { var configure = false }

/// recsfix2 (#14): the allowlist follows the connections, not only a save. A bot connected or deleted on a server with
/// alerts on sends the saved settings again (secrets from the Keychain) with the new list, once; deleting the server's
/// last agent sends an empty list through that agent, as no later tick reaches the server.
@Test @MainActor func theAllowlistFollowsBotsConnectedAndDeleted() async throws {
    let (store, target, box, _) = alertsStore { args in
        alertsPanelJSON(action: args[2], configured: true, enabled: true, running: true, result: args[2] == "configure" ? ["saved": true] : nil)
    }
    store.boxAlerts.idleSeconds = { 10_000 }  // Away from the Mac: no presence lease, the allowlist only.
    var settings = AlertSettings(); settings.ntfyURL = "https://ntfy.sh/konrad-alerts"
    await store.saveAlerts(settings, ntfyToken: "tk_secret_123", emailPassword: "", on: target)
    #expect(try lastSealed(box).profiles == ["reporter"])
    box.calls = []
    await store.renewAlertPresenceIfDue()
    #expect(box.calls.isEmpty, "the same profiles: nothing is sent")

    let jarvis = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); jarvis.hermesBaseURL = "https://box.example.invalid/v1"
    store.bots.append(jarvis)
    await store.renewAlertPresenceIfDue()
    #expect(box.calls.map { $0[2] } == ["configure"])
    let sealed = try lastSealed(box)
    #expect(sealed.profiles == ["grok-jarvis", "reporter"] && sealed.token == "tk_secret_123")

    box.calls = []
    store.delete(jarvis)
    await store.renewAlertPresenceIfDue()
    for _ in 0..<300 where box.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(box.calls.map { $0[2] } == ["configure"], "one push, from the deletion or the tick")
    #expect(try lastSealed(box).profiles == ["reporter"])

    box.calls = []
    store.delete(try #require(store.bots.first { $0.name == "Reporter" }))
    for _ in 0..<300 where box.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(box.calls.map { $0[2] } == ["configure"])
    #expect(try lastSealed(box).profiles == [], "the server's last agent deleted: the box alerts for none of its routines")
}

/// Settings 0.6.5 saved went without a list, so that box alerts for no routine: the first tick sends them again with one.
/// A push the box does not confirm waits `profilesRetry` (900 s), not one tick.
@Test @MainActor func settingsSavedWithoutAnAllowlistGetOneAtTheNextTick() async throws {
    let refusing = Refusing()
    let (store, target, box, keys) = alertsStore { args in
        if args[2] == "configure", refusing.configure { throw WebhookPanelError.refusal("swarmctl: try again later\n") }
        return alertsPanelJSON(action: args[2], configured: true, enabled: true, running: true, result: args[2] == "configure" ? ["saved": true] : nil)
    }
    store.boxAlerts.idleSeconds = { 10_000 }
    // What 0.6.5 left on this Mac: the settings, the token in the Keychain and the box's answer that alerts are on.
    var settings = AlertSettings(); settings.ntfyURL = "https://ntfy.sh/konrad-alerts"
    store.defaults.set(try JSONEncoder().encode(settings), forKey: "alerts.settings." + target)
    keys.setKey("tk_secret_123", for: AppStore.alertSecretAccount("ntfy", target: target))
    store.defaults.set(true, forKey: "alerts.on." + target)
    refusing.configure = true
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await store.renewAlertPresenceIfDue(now: start)
    #expect(box.calls.map { $0[2] } == ["status", "configure"])
    box.calls = []
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(60))
    #expect(box.calls.isEmpty, "refused: tried again later, not at every tick")
    refusing.configure = false
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(901))
    #expect(box.calls.map { $0[2] } == ["configure"])
    let sealed = try lastSealed(box)
    #expect(sealed.profiles == ["reporter"] && sealed.token == "tk_secret_123")
    box.calls = []
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(1_000))
    #expect(box.calls.isEmpty, "confirmed: sent once")
}

@Test @MainActor func aSaveWithoutAnySinkOrABoxRefusalShowsWhy() async throws {
    let (store, target, box, _) = alertsStore { _ in throw WebhookPanelError.refusal("swarmctl: choose ntfy, email or both\n") }
    await store.saveAlerts(AlertSettings(), ntfyToken: "", emailPassword: "", on: target)
    #expect(store.boxAlerts.state(for: target).error == AlertsCopy.needSink && box.calls.isEmpty)
    await store.refreshAlerts(on: target)
    #expect(store.boxAlerts.state(for: target).error == "The box refused: choose ntfy, email or both")
}

@Test @MainActor func theTestAlertReportsEachSink() async throws {
    let (store, target, _, _) = alertsStore { args in
        alertsPanelJSON(action: args[2], configured: true, enabled: true, running: true, result: args[2] == "test" ? ["sinks": ["ntfy": "sent", "email": "error: mail not sent"]] : nil)
    }
    await store.sendTestAlert(on: target)
    #expect(store.boxAlerts.state(for: target).notice == "Test alert: Email error: mail not sent · ntfy sent")
}

@Test @MainActor func thePresenceLeaseIsAPausedRoutineRenewedWhileTheUserIsHere() async throws {
    let server = FakeJobsServer()
    let (store, bot, host) = routinesStore(server)
    store.boxAlertsOn = true  // rel066: switched off in the release; this test is of the lease itself.
    let target = store.connection(of: bot)
    store.defaults.set(true, forKey: "alerts.on." + target)
    var idle: TimeInterval = 5
    store.boxAlerts.idleSeconds = { idle }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await store.renewAlertPresenceIfDue(now: start)
    let id = try #require(server.jobIDs.first)
    #expect(server.job(id)?["name"] as? String == "swarmhub-presence" && server.job(id)?["enabled"] as? Bool == false)
    #expect((server.job(id)?["prompt"] as? String)?.hasSuffix("until=1800000300") == true)
    let backend = try #require(try store.backend(for: bot) as? HermesBackend)
    #expect(try await HermesJobsClient(backend: backend).list().isEmpty, "not one of the user's routines")
    let before = requestLines(host).count
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(60))
    #expect(requestLines(host).count == before, "renewed every two minutes, not every tick")
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(121))
    #expect(requestLines(host).last == "PATCH /p/grok-jarvis/api/jobs/\(id)")
    #expect((server.job(id)?["prompt"] as? String)?.hasSuffix("until=1800000421") == true)
    idle = 700
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(400))
    #expect((server.job(id)?["prompt"] as? String)?.hasSuffix("until=1800000421") == true, "away from the Mac: the lease lapses")
    idle = 5
    store.handOffForQuit(budget: 5)
    #expect((server.job(id)?["prompt"] as? String)?.hasSuffix("until=0") == true, "quit ends the lease at once")
}

// MARK: recsfix3: owed pushes, revocation, newer settings win

/// A box that keeps a revision of its settings and refuses an automatic push over an older one, as swarm_alerts.py does.
@MainActor private final class RevisionBox {
    var revision = 0, refuse = false
    var calls: [(profile: String?, action: String)] = [], sealed: [[String: Any]] = []

    func answer(_ bot: Bot, _ arguments: [String]) throws -> String {
        calls.append((bot.hermesProfile, arguments[2]))
        guard arguments[2] == "configure" else {
            return alertsPanelJSON(action: arguments[2], configured: true, enabled: true, running: true, revision: revision)
        }
        if refuse { throw WebhookPanelError.refusal("swarmctl: try again later\n") }
        guard let blob = arguments.last, let settings = try JSONSerialization.jsonObject(with: try openSealed(blob)) as? [String: Any] else {
            throw WebhookPanelError.refusal("unsealed\n")
        }
        if let expected = settings["if_revision"] as? Int, expected != revision {
            return alertsPanelJSON(action: "configure", configured: true, enabled: true, running: true, result: ["saved": false, "stale": true], revision: revision)
        }
        revision += 1; sealed.append(settings)
        let enabled = settings["enabled"] as? Bool ?? true
        return alertsPanelJSON(action: "configure", configured: true, enabled: enabled, running: enabled, result: ["saved": true], revision: revision)
    }
}

@MainActor private func revisionStore(_ box: RevisionBox, keys: InMemoryKeyStore, defaults: UserDefaults = isolatedDefaults()) -> AppStore {
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: keys, defaults: defaults)
    store.boxAlertsOn = true  // rel066: switched off in the release; these tests are of the alerts themselves.
    store.alertsControl = { bot, arguments in try box.answer(bot, arguments) }
    store.boxAlerts.idleSeconds = { 10_000 }  // Away from the Mac: no presence lease, the settings only.
    return store
}

private func boxBot(_ name: String, profile: String) -> Bot {
    let bot = Bot(name: name, backend: .hermes, hermesProfile: profile); bot.hermesBaseURL = "https://box.example.invalid/v1"; return bot
}

private func ntfySettings() -> AlertSettings { var settings = AlertSettings(); settings.ntfyURL = "https://ntfy.sh/konrad-alerts"; return settings }

/// Waits for a push the store started on its own (a deletion or a retirement) to be answered and handled.
@MainActor private func settle(_ store: AppStore, _ target: String, until done: () -> Bool) async throws {
    for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    for _ in 0..<300 where store.boxAlerts.state(for: target).busy != nil { try await Task.sleep(for: .milliseconds(10)) }
}

/// recsfix3: deleting a server's last agent revokes the box's alerts (off, no profile), through that agent. When the box
/// does not confirm it, it stays owed across a relaunch (no agent on that server any more) and is retried with backoff
/// (15 min, then 30) until it is confirmed; then nothing more goes.
@Test @MainActor func aRevocationTheBoxRefusedIsRetriedWithBackoffAcrossALaunch() async throws {
    let box = RevisionBox(), keys = InMemoryKeyStore([:])
    let store = revisionStore(box, keys: keys)
    let reporter = boxBot("Reporter", profile: "reporter")
    store.bots = [reporter]
    let target = store.connection(of: reporter)
    #expect(await store.saveAlerts(ntfySettings(), ntfyToken: "tk_secret_123", emailPassword: "", on: target))
    box.refuse = true; box.calls = []
    let start = Date()
    store.delete(reporter)
    try await settle(store, target) { box.calls.contains { $0.action == "configure" } }
    #expect(box.calls.map { $0.action } == ["configure"] && box.calls.last?.profile == "reporter", "tried at once, through the deleted bot")

    let later = revisionStore(box, keys: keys, defaults: store.defaults)
    #expect(later.alertRunner(for: target) == nil, "no agent on that server any more")
    box.calls = []
    await later.renewAlertPresenceIfDue(now: start.addingTimeInterval(60))
    #expect(box.calls.isEmpty, "refused: not at every tick")
    await later.renewAlertPresenceIfDue(now: start.addingTimeInterval(1_000))
    #expect(box.calls.map { $0.action } == ["status", "configure"] && box.calls.allSatisfy { $0.profile == "reporter" })
    box.calls = []
    await later.renewAlertPresenceIfDue(now: start.addingTimeInterval(2_000))
    #expect(box.calls.isEmpty, "refused again: it waits twice as long")
    box.refuse = false
    await later.renewAlertPresenceIfDue(now: start.addingTimeInterval(2_900))
    #expect(box.calls.map { $0.action } == ["configure"])
    let revoked = try #require(box.sealed.last)
    #expect(revoked["enabled"] as? Bool == false && revoked["profiles"] as? [String] == [] && box.sealed.count == 2)
    #expect(!later.alertSettings(for: target).enabled && !later.defaults.bool(forKey: "alerts.on." + target))
    box.calls = []
    await later.renewAlertPresenceIfDue(now: start.addingTimeInterval(90_000))
    #expect(box.calls.isEmpty, "confirmed: nothing owed")
}

/// recsfix3: a revocation the store could not even send (another alerts call on that server in flight) goes at a later tick.
@Test @MainActor func aRevocationThrottledWhileTheServerWasBusyGoesAtALaterTick() async throws {
    let box = RevisionBox()
    let store = revisionStore(box, keys: InMemoryKeyStore([:]))
    let reporter = boxBot("Reporter", profile: "reporter")
    store.bots = [reporter]
    let target = store.connection(of: reporter)
    #expect(await store.saveAlerts(ntfySettings(), ntfyToken: "", emailPassword: "", on: target))
    store.boxAlerts.update(target) { $0.busy = .status }
    box.calls = []
    store.delete(reporter)
    try await Task.sleep(for: .milliseconds(300))
    #expect(box.calls.isEmpty)
    store.boxAlerts.update(target) { $0.busy = nil }
    await store.renewAlertPresenceIfDue(now: Date().addingTimeInterval(3_600))
    #expect(box.calls.map { $0.action } == ["configure"] && box.calls.last?.profile == "reporter")
    #expect(box.sealed.last?["enabled"] as? Bool == false && box.sealed.last?["profiles"] as? [String] == [])
}

/// recsfix3: retiring (archiving) a bot sends the server's new list at once, not only at a later change.
@Test @MainActor func retiringABotSendsTheNewListAtOnce() async throws {
    let box = RevisionBox()
    let store = revisionStore(box, keys: InMemoryKeyStore([:]))
    let reporter = boxBot("Reporter", profile: "reporter"), jarvis = boxBot("Jarvis", profile: "grok-jarvis")
    reporter.canManageBots = true
    store.bots = [reporter, jarvis]
    let target = store.connection(of: reporter)
    #expect(await store.saveAlerts(ntfySettings(), ntfyToken: "", emailPassword: "", on: target))
    #expect(box.sealed.last?["profiles"] as? [String] == ["grok-jarvis", "reporter"])
    box.calls = []
    await store.apply(.botRetired(name: "grok-jarvis"), manager: reporter)
    try await settle(store, target) { box.calls.contains { $0.action == "configure" } }
    #expect(jarvis.retiredOnBox && box.calls.map { $0.action } == ["configure"])
    #expect(box.sealed.last?["profiles"] as? [String] == ["reporter"] && box.sealed.last?["enabled"] as? Bool == true)
}

/// recsfix3: an automatic push names the revision this Mac saved. Settings another Mac saved since are newer: the box
/// refuses the push, and it is not tried again; once a refresh has shown them, nothing goes at all. A save by the user
/// always applies, and automatic pushes follow it again.
@Test @MainActor func anAutomaticPushNeverOverwritesNewerSettingsFromAnotherMac() async throws {
    let box = RevisionBox()
    let store = revisionStore(box, keys: InMemoryKeyStore([:]))
    let reporter = boxBot("Reporter", profile: "reporter")
    store.bots = [reporter]
    let target = store.connection(of: reporter)
    #expect(await store.saveAlerts(ntfySettings(), ntfyToken: "", emailPassword: "", on: target))
    #expect(box.revision == 1 && box.sealed.last?["if_revision"] == nil, "a save by the user names no revision")

    box.revision = 2  // Another Mac saved; this one has not read the box since.
    let jarvis = boxBot("Jarvis", profile: "grok-jarvis")
    store.bots.append(jarvis)
    box.calls = []
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    await store.renewAlertPresenceIfDue(now: start)
    #expect(box.calls.map { $0.action } == ["configure"])
    #expect(box.revision == 2 && box.sealed.count == 1, "refused by the box: the newer settings stay")
    box.calls = []
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(86_400))
    #expect(box.calls.isEmpty, "and not tried again")

    #expect(await store.saveAlerts(ntfySettings(), ntfyToken: "", emailPassword: "", on: target))
    #expect(box.revision == 3)
    box.calls = []
    store.delete(jarvis)
    try await settle(store, target) { box.calls.contains { $0.action == "configure" } }
    #expect(box.sealed.last?["if_revision"] as? Int == 3 && box.revision == 4 && box.sealed.last?["profiles"] as? [String] == ["reporter"])

    box.revision = 7  // Another Mac again; this time a refresh shows it before the agents change.
    await store.refreshAlerts(on: target)
    store.bots.append(boxBot("Twin", profile: "twin"))
    box.calls = []
    await store.renewAlertPresenceIfDue(now: start.addingTimeInterval(2 * 86_400))
    #expect(box.calls.isEmpty && box.revision == 7)
}

@MainActor @Test func alertsShotsRenderTheSection() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "AgentAppAlerts-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var lines: [String] = []
    #expect(await HeadlessSetup.render(to: directory, only: "alerts", output: { lines.append($0) }) == 0, "\(lines)")
    for name in HeadlessAlertsShots.names {
        let data = try Data(contentsOf: directory.appending(path: "\(name).png"))
        #expect(try #require(NSBitmapImageRep(data: data)).pixelsWide > 0 && data.count > 4_000, "\(name) looks blank")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == HeadlessAlertsShots.names.count, "only the alerts shots")
}
