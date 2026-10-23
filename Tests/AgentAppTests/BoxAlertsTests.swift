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
                     result: [String: Any]? = nil) -> String {
    let object: [String: Any] = [
        "schema": "swarmhub/alerts/1", "action": action, "result": result ?? NSNull(), "box_key": boxKey,
        "config": ["configured": configured, "enabled": enabled, "window": true, "sinks": configured ? ["ntfy"] : []],
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
