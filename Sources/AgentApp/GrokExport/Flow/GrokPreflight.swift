import Foundation
import Security

/// Where Grok Bot lives on this Mac. Injectable so tests use temp folders; the live values come from `GrokProtocol`.
struct GrokLocation: Sendable {
    /// `~/Library/Application Support/Grok Bot`.
    var dataFolder: URL
    /// `/Applications/Grok Bot.app`.
    var app: URL

    static func live() -> GrokLocation {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return GrokLocation(dataFolder: support.appending(path: GrokProtocol.dataFolderName, directoryHint: .isDirectory),
                            app: URL(fileURLWithPath: GrokProtocol.appPath, isDirectory: true))
    }

    var cacheFolder: URL { dataFolder.appending(path: GrokProtocol.cacheFolderName, directoryHint: .isDirectory) }
    var secretsFile: URL { dataFolder.appending(path: GrokProtocol.secretsFileName) }

    /// The installed app's `CFBundleShortVersionString`, or nil.
    func installedVersion() -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}

/// Everything that can be checked with no prompt and no network (P10c 1, and `--grok-probe` without `--live`): the
/// cache and roster shape, the account binding, the secrets file's structure and an attributes-only Keychain query.
/// Holds no secret: the secrets file is parsed for structure only and its ciphertext is not kept.
struct GrokPreflight: Sendable {
    enum Binding: String, Sendable { case holds, noSlot, mismatch, unknown }

    var appFound = false
    var dataFolderFound = false
    /// The installed Grok Bot version as the client headers send it (three numeric groups, else the fallback).
    var clientVersion = GrokProtocol.clientVersionFallback
    var versionReadable = false
    var cache: GrokCache?
    var cacheError: GrokCacheError?
    var secrets: GrokSecretsFile?
    var binding: Binding = .unknown
    /// The attributes-only query's OSStatus (nil when it was not run) and how long it took.
    var keychainStatus: OSStatus?
    var keychainMs = 0

    var keychainItemPresent: Bool { keychainStatus == errSecSuccess }
    var secretsShapeOK: Bool { secrets.map { $0.hasAccountsString && $0.activeAccountID != nil } ?? false }

    /// Full history can be offered: the cache is readable, one account is signed in and matches, and the item exists.
    var serverReady: Bool {
        GrokProtocol.serverHistoryEnabled && cache != nil && secretsShapeOK && binding != .mismatch && keychainItemPresent
    }

    /// Why only the cache can be imported, or nil when `serverReady`.
    var cacheOnlyReason: GrokImportRunError? {
        if serverReady { return nil }
        if !GrokProtocol.serverHistoryEnabled { return .serverHistoryOff }
        if !secretsShapeOK { return .signedOut }
        if binding == .mismatch { return .cache(.accountMismatch) }
        return .keychainItemMissing
    }

    /// Runs every check; never reads the Keychain item's data and never touches the network.
    static func run(location: GrokLocation, passwords: any GrokPasswordProvider) async -> GrokPreflight {
        await Task.detached(priority: .userInitiated) { check(location: location, passwords: passwords) }.value
    }

    private static func check(location: GrokLocation, passwords: any GrokPasswordProvider) -> GrokPreflight {
        var result = GrokPreflight()
        let files = FileManager.default
        result.appFound = files.fileExists(atPath: location.app.path)
        result.dataFolderFound = files.fileExists(atPath: location.dataFolder.path)
        let version = location.installedVersion()
        result.clientVersion = GrokRequestHeaders.clientVersion(fromShortVersion: version)
        result.versionReadable = version != nil
        do { result.cache = try GrokCacheReader(folder: location.cacheFolder).read() }
        catch let error as GrokCacheError { result.cacheError = error }
        catch { result.cacheError = .blobUnreadable }
        if let data = readSecrets(location.secretsFile) { result.secrets = try? GrokSecretsFile.parse(data: data) }
        if let cache = result.cache, let active = result.secrets?.activeAccountID {
            if let slot = cache.accountSlot {
                result.binding = GrokCredentials.accountBindingHolds(activeAccountID: active, accountSlotValue: slot) ? .holds : .mismatch
            } else {
                result.binding = .noSlot
            }
        }
        let start = ContinuousClock.now
        result.keychainStatus = passwords.probe()
        let elapsed = ContinuousClock.now - start
        result.keychainMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return result
    }

    /// Reads `sand-secrets.json` (a regular file, never a link), retrying once: Grok Bot may be rewriting it.
    static func readSecrets(_ url: URL) -> Data? {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink == false, values?.isRegularFile == true else { return nil }
        for _ in 0..<2 {
            if let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        }
        return nil
    }
}
