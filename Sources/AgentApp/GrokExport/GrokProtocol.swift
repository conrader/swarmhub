import Foundation

/// Every value that couples this app to Grok Bot's private formats: the drift register.
/// Captured from Grok Bot 0.70.2 on 2026-10-13. Each value says where it was found; when Grok Bot changes one of them,
/// this file is the only place to update, and `--grok-probe` (P10c) is how the change is noticed.
enum GrokProtocol {
    static let capturedFrom = "Grok Bot 0.70.2 on 2026-10-13"

    /// Turns the server half (Keychain read + private RPC) off; cache-only import keeps working. Decision D1.
    static let serverHistoryEnabled = true

    // MARK: The installed app (`/Applications/Grok Bot.app/Contents/Info.plist`)
    static let bundleIdentifier = "com.anysphere.sand"
    static let appPath = "/Applications/Grok Bot.app"
    /// Sent as `x-cursor-client-version` when the installed app's version cannot be read (three numeric groups).
    static let clientVersionFallback = "0.70.2"

    // MARK: Local data (`~/Library/Application Support/Grok Bot/`, read-only recon)
    static let dataFolderName = "Grok Bot"
    static let cacheFolderName = "sand-client-persistence"
    static let blobExtension = ".blob"
    static let secretsFileName = "sand-secrets.json"
    /// Blob file names are unpadded lowercase base32 of these keys.
    static let accountSlicePrefix = "sand.client.slice.account."
    static let rosterSuffix = ".roster.last-roster"
    static let transcriptInfix = ".transcript.replicas."
    /// Its value, percent-encoded, is the account segment of the slice keys; `cursor-accounts.active` is the lowercase hex
    /// SHA-256 of that segment (seen once, one account).
    static let accountSlotKey = "sand.client.slice.client-meta.account-slot"

    // MARK: `sand-secrets.json` keys (`electron-main/main-app.cjs`)
    /// A JSON *string* holding `{"active": <id>, "accounts": {<id>: {...}}}`.
    static let accountsKey = "cursor-accounts"
    static let activeKey = "active"
    static let accountsMapKey = "accounts"
    static let accessTokenKey = "cursor-access-token"
    static let teamIDKey = "cursor-selected-team-id"
    static let machineIDKey = "cursor-machine-id"
    /// Never decrypted: `cursor-refresh-token`, `local-exec-file-key`, the profile.

    // MARK: Electron safeStorage (Chromium OSCrypt on macOS)
    static let keychainService = "Grok Bot Safe Storage"
    static let keychainAccount = "Grok Bot Key"
    static let safeStorageSalt = Array("saltysalt".utf8)
    static let safeStorageIterations: UInt32 = 1003
    static let safeStorageKeyLength = 16
    static let safeStorageIV = [UInt8](repeating: 0x20, count: 16)
    static let safeStoragePrefix = Array("v10".utf8)
    /// `scoped:v1:<scope>:<base64>`: four colon-separated parts, the last is the safeStorage value.
    static let scopedPrefix = "scoped:v1:"

    // MARK: Server (`app.asar`, docs/P8a-findings.md)
    static let baseURL = URL(string: "https://api2.cursor.sh")!
    static let service = "aiserver.v1.GrokBotService"
    enum Method: String, Sendable, CaseIterable {
        case listTranscriptEntries = "ListGrokBotTranscriptEntries"
        case presignReads = "PresignSandBoxStoreReads"
    }
    static func url(for method: Method, base: URL = baseURL) -> URL { base.appending(path: "\(service)/\(method.rawValue)") }
    static let contentType = "application/proto"
    static let connectProtocolVersion = "1"
    static let connectTimeoutMs = "15000"
    static let requestTimeout: TimeInterval = 30
    static let pageLimit: UInt32 = 500
    static let minRequestInterval: Duration = .milliseconds(500)
    static let maxPagesPerBot = 400
    static let maxRequestsPerRun = 2000
    /// Response caps: a larger body is refused unread (`tooLarge`), never truncated.
    static let maxRPCResponseBytes = 32 << 20
    static let maxBlobResponseBytes = 16 << 20
    /// Decision D2: network errors and HTTP 502/503/504 only, at most 3 retries, after 1, 2 and 4 s, each paced.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
    static let retriedStatuses: Set<Int> = [502, 503, 504]
    /// Connect error codes that mean the interface moved (`protocolChanged`, never retried).
    static let protocolChangedCodes: Set<String> = ["not_found", "unimplemented"]
    /// A presigned blob is fetched from `blobs/<hash>`.
    static let blobPathPrefix = "blobs/"

    // MARK: Client headers (`getSandBackendClientHeaders` + `o_e` in main-app.cjs)
    /// Drift: 2026-10-13, renamed from Torvli/<version>, Konrad's rename (P18): the user-agent is `AppConstants.userAgent`,
    /// `SwarmHub/<version>` today; P10c's live step re-confirms Grok accepts it.
    /// Drift: changed 2026-10-13, Konrad approved. The app identifies itself honestly as `<app name>/<app version>`
    /// instead of Grok Bot's Electron user-agent (`Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36
    /// (KHTML, like Gecko) Sand/<version> Safari/537.36`, from `o_e` in main-app.cjs). P10.0 step (g) showed the server
    /// accepts it (HTTP 200, docs/P10-spike-findings.md). Every other header below is still the one Grok Bot sends.
    static func userAgent(appVersion: String) -> String { AppConstants.userAgent(version: appVersion) }
    /// The user-agent version when the app's own version is not a plain dotted version (a bare SwiftPM build).
    static let appVersionFallback = "dev"
    static let clientHeaders: [(String, String)] = [
        ("x-cursor-client-type", "sand"), ("x-sand-box-namespace", "prod"),
        ("x-cursor-client-os", "darwin"), ("x-cursor-client-source", "sand-desktop"), ("x-ghost-mode", "true"),
    ]
    /// `AA()` in main-app.cjs: the XOR chain starts here and the timestamp is `floor(ms / 1e6)`.
    static let checksumSeed: UInt8 = 165
    static let checksumDivisor: Int64 = 1_000_000
    static let machineIDMaxLength = 127
}
