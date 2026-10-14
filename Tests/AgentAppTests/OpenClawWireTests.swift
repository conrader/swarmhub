import Foundation
import Testing
@testable import AgentApp

// P12 Part A: frames, JSON, URL rules, the Gateway store and the redactor. Synthetic values only.

@Test func framesDecodeIgnoringUnknownFieldsAndEvents() throws {
    let res = GatewayFrame.decode(#"{"type":"res","id":"a","ok":true,"payload":{"x":1},"extra":{"y":[1,2]}}"#)
    #expect(res == .response(.init(id: "a", ok: true, payload: ["x": 1], error: nil)))
    let event = GatewayFrame.decode(#"{"type":"event","event":"brand.new.event","payload":{"k":"v"},"seq":7,"stateVersion":{"presence":2}}"#)
    #expect(event == .event(.init(event: "brand.new.event", payload: ["k": "v"], seq: 7)))
    let failed = try #require(GatewayFrame.decode(#"{"type":"res","id":"b","ok":false,"error":{"code":"NOT_PAIRED","message":"m","details":{"code":"PAIRING_REQUIRED","requestId":"r1","reason":"not-paired","new":true},"retryable":true,"retryAfterMs":500}}"#))
    guard case .response(let response) = failed, let error = response.error else { Issue.record("no error"); return }
    #expect(error.code == "NOT_PAIRED" && error.details?.code == "PAIRING_REQUIRED" && error.details?.requestId == "r1" && error.retryable && error.retryAfterMs == 500)
    #expect(error.has("PAIRING_REQUIRED") && error.has("NOT_PAIRED") && !error.has("AUTH_TOKEN_MISMATCH"))
    #expect(GatewayFrame.decode(#"{"type":"hello","id":"x"}"#) == nil, "unknown frame types are skipped")
}

@Test func malformedFramesNeverCrash() {
    var generator = SystemRandomNumberGenerator()
    let seeds = [#"{"type":"res","id":1,"ok":"yes"}"#, #"{"type":"event"}"#, #"{"type":"req","id":"a"}"#, "[]", "null", "{", "", "\u{0}", #"{"type":"res","id":"a","ok":true,"payload":"#,
                 #"{"type":"event","event":"chat","payload":{"seq":"NaN"}}"#, String(repeating: "[", count: 5_000)]
    for seed in seeds { _ = GatewayFrame.decode(seed) }
    let alphabet = Array(#"{}[]":,"type"res"event"req"ok"true"1e9-"#)
    for _ in 0..<2_000 {
        let text = String((0..<Int.random(in: 0...60, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
        _ = GatewayFrame.decode(text)
    }
    #expect(GatewayFrame.decode(#"{"type":"res","id":1,"ok":true}"#) == nil, "a numeric id is malformed")
}

@Test func jsonEncodesIntegersWithoutFractionsAndSortedKeys() {
    let value: GatewayJSON = ["b": .int(1_737_264_000_000), "a": [true, .null, "x"], "c": .number(1.5)]
    #expect(value.jsonText == #"{"a":[true,null,"x"],"b":1737264000000,"c":1.5}"#)
    #expect(GatewayJSON.parse(value.jsonText) == value)
    #expect(GatewayJSON.number(3).int == 3 && GatewayJSON.number(3.5).int == nil && GatewayJSON.string("3").int == nil)
}

@Test func requestTextIsAReqFrame() {
    let text = GatewayFrame.requestText(id: "id-1", method: "agents.list", params: [:])
    #expect(text == #"{"id":"id-1","method":"agents.list","params":{},"type":"req"}"#)
}

// MARK: URL rules

@Test(arguments: [
    ("ws://127.0.0.1", "ws://127.0.0.1:18789"), ("http://localhost:9000", "ws://localhost:9000"), ("https://gw-test.example", "wss://gw-test.example"),
    ("wss://gw-test.example/gateway", "wss://gw-test.example/gateway"), ("ws://[::1]", "ws://[::1]:18789"), ("  ws://127.0.0.2:18789/  ", "ws://127.0.0.2:18789"),
])
func gatewayURLsNormalise(input: String, expected: String) throws {
    #expect(try GatewayURLRules.validate(input, allowPrivatePlaintext: false).get().absoluteString == expected)
}

@Test func gatewayURLRulesRefuseWhatTheyMust() {
    func problem(_ text: String, _ allow: Bool = false) -> GatewayURLRules.Problem? {
        if case .failure(let problem) = GatewayURLRules.validate(text, allowPrivatePlaintext: allow) { return problem }; return nil
    }
    #expect(problem("ftp://gw-test.example") == .scheme)
    #expect(problem("ws://user:pass@127.0.0.1") == .userInfo)
    #expect(problem("ws://127.0.0.1:18789/?token=x") == .queryOrFragment && problem("ws://127.0.0.1#x") == .queryOrFragment)
    #expect(problem("") == .invalid && problem("not a url") == .invalid)
    #expect(problem("ws://gw-test.example") == .plaintextPublic, "public ws:// is refused, even when ticked")
    #expect(problem("ws://gw-test.example", true) == .plaintextPublic)
    for host in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "169.254.3.4", "100.100.1.1", "box.local", "[fd00::1]", "[fe80::1]"] {
        #expect(problem("ws://\(host)") == .plaintextPrivate, "\(host) needs the tick box")
        #expect(problem("ws://\(host)", true) == nil, "\(host) passes with the tick box")
    }
    #expect(problem("ws://172.32.0.1") == .plaintextPublic && problem("ws://100.128.0.1") == .plaintextPublic, "outside RFC 1918 / CGNAT")
}

@Test func tokensGoInPlaintextOnlyToLoopbackOrATickedPrivateHost() throws {
    let loop = try GatewayURLRules.validate("ws://127.0.0.1", allowPrivatePlaintext: false).get()
    let lan = try GatewayURLRules.validate("ws://192.168.1.2", allowPrivatePlaintext: true).get()
    let tls = try GatewayURLRules.validate("wss://gw-test.example", allowPrivatePlaintext: false).get()
    #expect(GatewayURLRules.permitsToken(loop, allowPrivatePlaintext: false) && GatewayURLRules.permitsToken(tls, allowPrivatePlaintext: false))
    #expect(GatewayURLRules.permitsToken(lan, allowPrivatePlaintext: true) && !GatewayURLRules.permitsToken(lan, allowPrivatePlaintext: false))
    #expect(GatewayURLRules.isTrusted(loop) && GatewayURLRules.isTrusted(tls) && !GatewayURLRules.isTrusted(lan), "device-token retry only on loopback or wss")
}

// MARK: Store

@Test func gatewayStoreRoundTripsWithoutSecrets() throws {
    let defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    let store = GatewayStore(defaults: defaults, keyStore: keys)
    var gateway = OpenClawGateway(name: "Lab", url: "wss://gw-test.example"); gateway.keepsToken = true
    store.upsert(gateway)
    GatewayCredentials(gateway: gateway, keyStore: keys).setSharedToken("  \(fakeSharedToken) ")
    #expect(store.load() == [gateway])
    #expect(keys.key(for: gateway.tokenAccount) == fakeSharedToken, "trimmed, in the Keychain")
    let raw = String(decoding: try #require(defaults.data(forKey: GatewayStore.defaultsKey)), as: UTF8.self)
    #expect(!raw.contains(fakeSharedToken) && raw.contains("gw-test.example"))
    #expect(gateway.accounts == ["openclaw.\(gateway.id).token", "openclaw.\(gateway.id).device-token", "openclaw.\(gateway.id).device-key"])
}

@Test func changingTheURLDropsTheDeviceTokenAndForgetDeletesEverything() {
    let defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    let store = GatewayStore(defaults: defaults, keyStore: keys)
    var gateway = OpenClawGateway(name: "Lab", url: "ws://127.0.0.1:18789")
    store.upsert(gateway)
    gateway.accounts.forEach { keys.setKey("secret-\($0)", for: $0) }
    gateway.name = "Renamed"; store.upsert(gateway)
    #expect(keys.key(for: gateway.deviceTokenAccount) == "secret-\(gateway.deviceTokenAccount)", "a rename keeps the pairing")
    gateway.url = "ws://127.0.0.1:18790"; store.upsert(gateway)
    #expect(keys.key(for: gateway.deviceTokenAccount).isEmpty && !keys.key(for: gateway.deviceKeyAccount).isEmpty)
    store.forget(gateway)
    #expect(store.load().isEmpty && keys.all().isEmpty)
}

@Test func theOldOpenClawURLMigratesOnceWithoutAToken() {
    let defaults = isolatedDefaults(), keys = InMemoryKeyStore()
    defaults.set("ws://127.0.0.1:18789", forKey: GatewayStore.legacyURLKey)
    let store = GatewayStore(defaults: defaults, keyStore: keys)
    let migrated = store.migrateLegacyURL()
    #expect(migrated?.name == "OpenClaw" && migrated?.url == "ws://127.0.0.1:18789" && store.load().count == 1)
    #expect(defaults.object(forKey: GatewayStore.legacyURLKey) == nil && keys.all().isEmpty)
    #expect(store.migrateLegacyURL() == nil && store.load().count == 1, "once")
}

@MainActor @Test func theStoreLoadsGatewaysAtLaunchWithoutCreatingTheHub() {
    let defaults = isolatedDefaults()
    defaults.set("ws://127.0.0.1:18789", forKey: GatewayStore.legacyURLKey)
    let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    #expect(store.openClawGateways.map(\.name) == ["OpenClaw"])
    #expect(store.openClawWakeObserver == nil, "no hub (and no observer) until something asks for it")
}

@Test func theRedactorRemovesEverySecret() {
    let text = GatewayRedactor.redact("failed with test-shared-token and device-token-abc and seedseed", secrets: [fakeSharedToken, "device-token-abc", "seedseed", ""])
    #expect(text == "failed with [redacted] and [redacted] and [redacted]")
}

@MainActor @Test func headlessLinesCarryNoSecrets() async throws {
    let (gateway, _) = fakeGatewaySetup()
    var summary = GatewaySummary(protocolVersion: 4, serverVersion: "2026.10.3")
    summary.scopes = OpenClawClient.scopes; summary.methods = ["chat.send", "agents.list"]
    #expect(HeadlessOpenClaw.line(gateway, state: "connected", summary: summary, agents: 2)
            == "Test Gateway | ws://127.0.0.1:18789 | connected | 2026.10.3 | protocol 4 | operator.read,operator.write,operator.approvals | 2 agents | 2 methods")
    #expect(HeadlessOpenClaw.line(gateway, state: "Can’t reach", summary: nil, agents: nil) == "Test Gateway | ws://127.0.0.1:18789 | Can’t reach | - | - | - | - | -")
    var lines: [String] = []
    let code = await HeadlessOpenClaw.check(gateways: [], hub: OpenClawHub(status: OpenClawStatus(), keyStore: InMemoryKeyStore()), output: { lines.append($0) })
    #expect(code == 0 && lines == ["No OpenClaw Gateways configured."])
}
