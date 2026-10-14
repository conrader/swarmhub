import CommonCrypto
import Foundation
import Security
import Testing
@testable import AgentApp

/// A synthetic Grok Bot install for the P10c pipeline tests: the fixture cache, a `sand-secrets.json` encrypted with a
/// synthetic password, an Info.plist, a fake password provider and a FakeGrok holding each conversation's history.
/// Nothing here reads the real Keychain, Grok Bot's folder or the network.
enum GrokRunIDs {
    static let jarvis = "00000000-0000-4000-8000-000000000001"
    static let finance = "00000000-0000-4000-8000-000000000002"
    static let plain = "00000000-0000-4000-8000-000000000003"
    static let group = "00000000-0000-4000-8000-000000000004"
}

/// Counts every data read; can deny, block until released, or report a missing item.
final class FakePasswords: GrokPasswordProvider, @unchecked Sendable {
    static let password = "synthetic-pass-SECRET-77"
    private let lock = NSLock()
    private var count = 0, probes = 0
    var failure: GrokKeychainError?
    var probeStatus: OSStatus = errSecSuccess
    /// When set, `readPassword` waits for it (a dialog nobody has answered yet).
    var hold: DispatchSemaphore?

    var reads: Int { lock.withLock { count } }
    var probeCount: Int { lock.withLock { probes } }

    func probe() -> OSStatus { lock.withLock { probes += 1 }; return probeStatus }

    func readPassword() throws -> [UInt8] {
        lock.withLock { count += 1 }
        hold?.wait()
        if let failure { throw failure }
        return Array(Self.password.utf8)
    }
}

final class GrokWorld: @unchecked Sendable {
    static let now = Date(timeIntervalSince1970: 1_760_000_000)
    let root = FileManager.default.temporaryDirectory
        .appending(path: "AgentAppTests-grok-\(UUID().uuidString)", directoryHint: .isDirectory)
    let fake = FakeGrok()
    let passwords = FakePasswords()
    let clock = GrokFakeClock()
    let gate = GrokKeychainGate()
    var location: GrokLocation {
        GrokLocation(dataFolder: root.appending(path: "Grok Bot", directoryHint: .isDirectory), app: root.appending(path: "Grok Bot.app"))
    }

    /// The signed-in account id in `sand-secrets.json`.
    let activeAccount: String

    /// `history`: seqs per conversation on the fake server; the cache's own entries keep their seqs. `slot`: write an
    /// account-slot blob with this raw value and rename the fixture's account segment to its percent-encoded form;
    /// the signed-in account is then the SHA-256 of the raw value unless `activeAccount` says otherwise.
    init(tokenExp: TimeInterval = 4_102_444_800, history: [String: Int64] = [
        GrokRunIDs.jarvis: 30, GrokRunIDs.finance: 5, GrokRunIDs.plain: 3, GrokRunIDs.group: 4,
    ], slot: String? = nil, activeAccount: String? = nil) throws {
        self.activeAccount = activeAccount ?? slot.map { GrokCredentials.sha256Hex(Array($0.utf8)) } ?? "acct-synthetic"
        let files = FileManager.default
        try files.createDirectory(at: location.cacheFolder, withIntermediateDirectories: true)
        let segment = slot.flatMap { GrokCacheReader.encodings(of: $0).first } ?? "acct-fake-0001"
        for name in try files.contentsOfDirectory(atPath: grokCacheFixture.path) where name.hasSuffix(".blob") {
            let key = try #require(GrokBase32.sliceKey(forFileName: name)).replacingOccurrences(of: "acct-fake-0001", with: segment)
            try files.copyItem(at: grokCacheFixture.appending(path: name), to: location.cacheFolder.appending(path: Self.fileName(key)))
        }
        if let slot {
            let blob = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "value": slot])
            try blob.write(to: location.cacheFolder.appending(path: Self.fileName(GrokProtocol.accountSlotKey)))
        }
        try files.createDirectory(at: location.app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.70.2"], format: .xml, options: 0)
        try plist.write(to: location.app.appending(path: "Contents/Info.plist"))
        try writeSecrets(tokenExp: tokenExp)
        fake.history = history.mapValues { top in Dictionary(uniqueKeysWithValues: (1...top).map { ($0, FakeGrok.entry($0)) }) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func environment() -> GrokImportEnvironment {
        let fake = fake
        return GrokImportEnvironment(location: location, passwords: passwords, gate: gate, makeSession: { fake.session },
                                     baseURL: fake.baseURL, clock: clock, now: { GrokWorld.now }, appVersion: "1.0")
    }

    @MainActor func store(server: String? = nil, url: URL = temporaryStore()) -> AppStore {
        let defaults = isolatedDefaults()
        if let server { defaults.set(server, forKey: "hermesBaseURL") }
        return AppStore(storeURL: url, autoConfigureHermes: false, keyStore: InMemoryKeyStore([:]), defaults: defaults, hermesSession: UnreachableProtocol.session)
    }

    /// Rewrites `sand-secrets.json` (Grok Bot refreshed its sign-in).
    func writeSecrets(tokenExp: TimeInterval) throws {
        let key = try GrokSafeStorage.deriveKey(password: Array(FakePasswords.password.utf8))
        let token = Self.jwt(exp: tokenExp)
        let accounts: [String: Any] = ["active": activeAccount, "accounts": [activeAccount: [
            GrokProtocol.accessTokenKey: Self.encrypt(token, key: key), GrokProtocol.teamIDKey: Self.encrypt("42", key: key),
            "cursor-refresh-token": Self.encrypt("refresh-SECRET-never-read", key: key),
        ]]]
        let accountsString = String(decoding: try JSONSerialization.data(withJSONObject: accounts), as: UTF8.self)
        let root: [String: Any] = [GrokProtocol.accountsKey: accountsString,
                                   GrokProtocol.machineIDKey: Self.encrypt(GrokFixtureSecrets.machineID, key: key)]
        try JSONSerialization.data(withJSONObject: root).write(to: location.secretsFile)
    }

    /// `<unpadded lowercase base32 of the key>.blob`, as Grok Bot names its cache files.
    static func fileName(_ key: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = "", value = 0, bits = 0
        for byte in key.utf8 {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out + GrokProtocol.blobExtension
    }

    /// The synthetic token for an expiry: header and signature fixed, so the leak scan can search for it.
    static func jwt(exp: TimeInterval) -> String {
        let payload = Data(#"{"exp":\#(Int(exp)),"sub":"synthetic"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJzeW50aGV0aWMiOiJ0cnVlIn0.\(payload).U1lOVEhFVElDLVNFQ1JFVC1UT0tFTg"
    }

    static func encrypt(_ text: String, key: [UInt8]) -> String {
        let plain = Array(text.utf8), iv = GrokProtocol.safeStorageIV
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        _ = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                    key, key.count, iv, plain, plain.count, &out, out.count, &moved)
        return Data(GrokProtocol.safeStoragePrefix + out[0..<moved]).base64EncodedString()
    }
}

/// A thread-safe flag the fake's intercept reads.
final class GrokSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// The list requests the fake received, decoded: (agent, before_seq).
func grokListRequests(_ fake: FakeGrok) -> [(agent: String, before: Int64?, limit: UInt64)] {
    let lists = fake.requests.filter { $0.method == "POST" && $0.url.hasSuffix(GrokProtocol.Method.listTranscriptEntries.rawValue) }
    return lists.compactMap { request in
        guard let fields = try? GrokProtobuf.parse(request.body), case .bytes(let agent)? = fields[1]?.first,
              case .varint(let limit)? = fields[4]?.first else { return nil }
        var before: Int64?
        if case .varint(let value)? = fields[3]?.first { before = Int64(value) }
        return (String(decoding: agent, as: UTF8.self), before, limit)
    }
}

/// Polls until `condition` holds (bounded by `waitCeiling`): for states reached on another thread.
@MainActor func grokWait(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + waitCeiling
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout() }
        try await Task.sleep(for: .milliseconds(10))
    }
}
