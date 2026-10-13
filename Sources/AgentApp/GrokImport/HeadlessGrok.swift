import Foundation
import Security

/// Throwaway P10.0 harness: `AgentApp --grok-spike <report.json>`. It settles, against the real Keychain, folder
/// and server, the macOS unknowns no one can read from a keyboard (see briefs/P10.md P10.0). Deleted in P10c.
///
/// The report holds numbers, booleans and non-secret shape strings only (0600, rewritten after each step so a hang
/// keeps earlier results). Steps (f)/(g) make the one live RPC; they run only under the packaged app started with
/// `open -n`, with Konrad at the Mac. This file never prints secrets and never logs message text.
@MainActor enum HeadlessGrok {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard let flag = arguments.firstIndex(of: "--grok-spike") else { return nil }
        guard arguments.indices.contains(flag + 1) else { print("Usage: AgentApp --grok-spike <report.json>"); return 64 }
        let path = (arguments[flag + 1] as NSString).expandingTildeInPath
        return run(reportPath: URL(fileURLWithPath: path))
    }

    // MARK: Report (numbers/booleans/non-secret shape strings only)

    struct Report: Codable {
        var startedAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        var version: String = ""
        var stepA_probe: StepTimed?
        var stepB_cache: CacheStep?
        var stepC_secrets: SecretsStep?
        var stepD_read: ReadStep?
        var stepE_decrypt: DecryptStep?
        var stepF_live: LiveStep?
        var stepG_honestUA: Int?

        struct StepTimed: Codable { var osStatus: Int32; var ms: Int }
        struct CacheStep: Codable { var readable: Bool; var errno: Int32; var ms: Int; var blobCount: Int; var rosterRows: Int }
        struct SecretsStep: Codable { var hasAccountsString: Bool; var hasActiveAccount: Bool; var accountCount: Int; var hasMachineID: Bool }
        struct ReadStep: Codable { var osStatus: Int32; var ms: Int; var byteCount: Int }
        struct DecryptStep: Codable {
            var tokenShapeOK: Bool; var tokenSegments: Int; var expSecondsFromNow: Int64
            var machineIDLength: Int; var teamIDNumeric: Bool; var accountBinding: String
        }
        struct LiveStep: Codable { var httpStatus: Int; var networkProtocol: String; var bytesStartGzip: Bool; var rowsDecoded: Int; var newestSeq: Int64 }
    }

    static func run(reportPath: URL) -> Int32 {
        var report = Report()
        report.version = GrokRequestHeaders.clientVersion(fromShortVersion: installedGrokVersion())
        func flush() { write(report, to: reportPath) }
        flush()

        let keychain = GrokKeychain()
        // (a) attributes-only probe — must be silent and under 500 ms.
        report.stepA_probe = timed { keychain.probe() }
        flush()

        // (b) cache: list, count .blob, read the roster.
        report.stepB_cache = cacheStep()
        flush()

        // (c) secrets-file structure, nothing decrypted.
        let secretsURL = dataFolder().appending(path: GrokProtocol.secretsFileName)
        let secretsData = try? Data(contentsOf: secretsURL)
        if let secretsData, let parsed = try? GrokSecretsFile.parse(data: secretsData) {
            report.stepC_secrets = .init(hasAccountsString: parsed.hasAccountsString, hasActiveAccount: parsed.activeAccountID != nil,
                                         accountCount: parsed.accountIDs.count, hasMachineID: parsed.hasMachineID)
        }
        flush()

        // (d) the one Keychain read.
        print("KEYCHAIN PROMPT COMING — Konrad: click Allow (not Always Allow)")
        fflush(stdout)
        var password: [UInt8] = []
        let start = Date()
        let readStatus: OSStatus
        do { password = try keychain.readPassword(); readStatus = errSecSuccess }
        catch let error as GrokKeychainError { readStatus = osStatus(from: error) }
        catch { readStatus = errSecInternalError }
        report.stepD_read = .init(osStatus: readStatus, ms: ms(since: start), byteCount: password.count)
        flush()

        // (e) derive, decrypt three values, shapes only.
        if !password.isEmpty, let secretsData {
            report.stepE_decrypt = decryptStep(password: &password, secretsData: secretsData)
        }
        GrokSafeStorage.zero(&password)
        flush()

        // (f)/(g) the one live RPC and the honest-UA probe. Guarded by the flag so cache-only builds never compile it out.
        if GrokProtocol.serverHistoryEnabled, let secretsData, let agentID = fewestEntriesAgentID() {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await liveSteps(agentID: agentID, secretsData: secretsData, report: &report)
                semaphore.signal()
            }
            semaphore.wait()
            flush()
        }
        return 0
    }

    // MARK: Steps

    private static func timed(_ body: () -> OSStatus) -> Report.StepTimed {
        let start = Date()
        let status = body()
        return .init(osStatus: status, ms: ms(since: start))
    }

    private static func cacheStep() -> Report.CacheStep {
        let start = Date()
        let cacheURL = dataFolder().appending(path: GrokProtocol.cacheFolderName)
        var names: [String] = []
        var errnoValue: Int32 = 0
        do { names = try FileManager.default.contentsOfDirectory(atPath: cacheURL.path) }
        catch { errnoValue = Int32((error as NSError).code) }
        let blobs = names.filter { $0.hasSuffix(GrokProtocol.blobExtension) }
        var rosterRows = 0
        var readable = false
        for name in blobs {
            guard let key = decodeBlobName(name), key.hasSuffix(GrokProtocol.rosterSuffix) else { continue }
            if let data = try? Data(contentsOf: cacheURL.appending(path: name)),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = root["value"] as? [String: Any], let rows = value["rows"] as? [Any] {
                rosterRows = rows.count
                readable = true
            }
            break
        }
        return .init(readable: readable, errno: errnoValue, ms: ms(since: start), blobCount: blobs.count, rosterRows: rosterRows)
    }

    private static func decryptStep(password: inout [UInt8], secretsData: Data) -> Report.DecryptStep? {
        guard let encrypted = try? GrokSecretsFile.encryptedAccount(data: secretsData) else { return nil }
        var key = (try? GrokSafeStorage.deriveKey(password: password)) ?? []
        defer { GrokSafeStorage.zero(&key) }
        guard !key.isEmpty, let token = try? GrokSafeStorage.decryptText(encrypted.accessToken, key: key) else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false).count
        let exp = jwtExpSecondsFromNow(token)
        var machineLen = 0
        if let m = encrypted.machineID, let text = try? GrokSafeStorage.decryptText(m, key: key) {
            machineLen = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        }
        var teamNumeric = false
        if let t = encrypted.teamID, let text = try? GrokSafeStorage.decryptText(t, key: key) {
            teamNumeric = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 > 0 } ?? false
        }
        let binding = accountBindingDescription(activeAccountID: encrypted.activeAccountID)
        return .init(tokenShapeOK: GrokCredentials.tokenSegmentsValid(token), tokenSegments: segments,
                     expSecondsFromNow: exp, machineIDLength: machineLen, teamIDNumeric: teamNumeric, accountBinding: binding)
    }

    private static func liveSteps(agentID: String, secretsData: Data, report: inout Report) async {
        // Decrypt afresh for the live call; the key and token live only in this scope.
        guard let encrypted = try? GrokSecretsFile.encryptedAccount(data: secretsData) else { return }
        var password = (try? GrokKeychain().readPassword()) ?? []
        defer { GrokSafeStorage.zero(&password) }
        guard !password.isEmpty, var key = try? GrokSafeStorage.deriveKey(password: password) else { return }
        defer { GrokSafeStorage.zero(&key) }
        guard let creds = try? GrokCredentials.decrypt(from: encrypted, key: key, now: Date()) else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let body = GrokProtobuf.encodeListRequest(agentID: agentID, limit: 2)

        if let result = try? await liveRPC(body: body, creds: creds, nowMs: nowMs, version: report.version, honestUA: false) {
            report.stepF_live = result
        }
        if let honest = try? await liveRPC(body: body, creds: creds, nowMs: nowMs, version: report.version, honestUA: true) {
            report.stepG_honestUA = honest.httpStatus
        }
    }

    private static func liveRPC(body: [UInt8], creds: GrokCredentials, nowMs: Int64, version: String, honestUA: Bool) async throws -> Report.LiveStep {
        var request = URLRequest(url: GrokProtocol.url(for: .listTranscriptEntries))
        request.httpMethod = "POST"
        request.httpBody = Data(body)
        request.timeoutInterval = GrokProtocol.requestTimeout
        for (name, value) in GrokRequestHeaders.rpcHeaders(token: creds.token.reveal(), machineID: creds.machineID.reveal(),
                                                           teamID: creds.teamID, version: version, nowMs: nowMs) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(GrokProtocol.contentType, forHTTPHeaderField: "content-type")
        request.setValue(GrokProtocol.connectProtocolVersion, forHTTPHeaderField: "connect-protocol-version")
        request.setValue(GrokProtocol.connectTimeoutMs, forHTTPHeaderField: "connect-timeout-ms")
        request.setValue("gzip", forHTTPHeaderField: "accept-encoding")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        if honestUA { request.setValue("Torvli/\(version)", forHTTPHeaderField: "user-agent") }

        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let bytes = [UInt8](data)
        let gzip = bytes.count >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b
        var rows = 0
        var newest: Int64 = 0
        if let decoded = try? GrokProtobuf.decodeListResponse(bytes) {
            rows = decoded.count
            newest = decoded.map(\.seq).max() ?? 0
        }
        let metrics = (response as? HTTPURLResponse).flatMap { _ in "" } ?? ""
        _ = metrics
        return .init(httpStatus: http?.statusCode ?? -1, networkProtocol: protocolName(from: response),
                     bytesStartGzip: gzip, rowsDecoded: rows, newestSeq: newest)
    }

    // MARK: Helpers

    private static func dataFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: GrokProtocol.dataFolderName)
    }

    private static func installedGrokVersion() -> String? {
        let plist = URL(fileURLWithPath: GrokProtocol.appPath).appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    private static func fewestEntriesAgentID() -> String? {
        let cacheURL = dataFolder().appending(path: GrokProtocol.cacheFolderName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheURL.path) else { return nil }
        var best: (count: Int, id: String)?
        for name in names where name.hasSuffix(GrokProtocol.blobExtension) {
            guard let key = decodeBlobName(name), let range = key.range(of: GrokProtocol.transcriptInfix) else { continue }
            let id = String(key[range.upperBound...])
            guard let data = try? Data(contentsOf: cacheURL.appending(path: name)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = root["value"] as? [String: Any] else { continue }
            let count = (value["entries"] as? [Any])?.count ?? 0
            if best == nil || count < best!.count { best = (count, id) }
        }
        return best?.id
    }

    private static func accountBindingDescription(activeAccountID: String) -> String {
        let cacheURL = dataFolder().appending(path: GrokProtocol.cacheFolderName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheURL.path) else { return "no-cache" }
        var slotValue: String?
        var segments = Set<String>()
        for name in names where name.hasSuffix(GrokProtocol.blobExtension) {
            guard let key = decodeBlobName(name), key.hasPrefix(GrokProtocol.accountSlicePrefix) else { continue }
            let rest = key.dropFirst(GrokProtocol.accountSlicePrefix.count)
            if let dot = rest.firstIndex(of: ".") { segments.insert(String(rest[..<dot])) }
            if key == GrokProtocol.accountSlotKey, let data = try? Data(contentsOf: cacheURL.appending(path: name)),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                slotValue = (root["value"] as? String) ?? (root["value"] as? [String: Any])?["value"] as? String
            }
        }
        guard let slotValue else { return segments.count > 1 ? "needs-account-choice" : "no-slot" }
        let encoded = slotValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slotValue
        return GrokCredentials.accountBindingHolds(activeAccountID: activeAccountID, accountSlotValue: encoded) ? "holds" : "mismatch"
    }

    private static func jwtExpSecondsFromNow(_ token: String) -> Int64 {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let payload = GrokCredentials.base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = claims["exp"] as? Double else { return 0 }
        return Int64(exp - Date().timeIntervalSince1970)
    }

    /// Minimal unpadded lowercase RFC 4648 base32 decode for the spike (GrokBase32 with the full reject rules
    /// arrives in P10a). A bad character or undecodable name is simply skipped here.
    private static func decodeBlobName(_ name: String) -> String? {
        guard name.hasSuffix(GrokProtocol.blobExtension) else { return nil }
        let stem = String(name.dropLast(GrokProtocol.blobExtension.count)).lowercased()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0, value = 0
        var out: [UInt8] = []
        for char in stem {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((value >> bits) & 0xFF)) }
        }
        return String(bytes: out, encoding: .utf8)
    }

    private static func protocolName(from response: URLResponse) -> String {
        // networkProtocolName is only exposed via URLSessionTaskMetrics; the spike records "" when unknown.
        ""
    }

    private static func osStatus(from error: GrokKeychainError) -> OSStatus {
        switch error {
        case .denied(let s), .unexpected(let s): return s
        case .itemMissing: return errSecItemNotFound
        case .keychainLocked: return -25308
        case .interactionNotAllowed: return errSecInteractionNotAllowed
        }
    }

    private static func ms(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    private static func write(_ report: Report, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
