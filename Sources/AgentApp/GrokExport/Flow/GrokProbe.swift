import Foundation
import Security

/// The standing drift check (`--grok-probe`, run after every Grok Bot update). Without `live` it never prompts and never
/// uses the network: Grok Bot's version, the cache and secrets-file shape, whether the Keychain item exists, roster counts.
/// With `live` it also makes the one Keychain read (one Allow), checks the sign-in's shape and fetches the canary page.
/// Booleans, counts and the Grok Bot version only: nothing that came from Grok's servers or the sign-in.
struct GrokProbeReport: Codable, Sendable, Equatable {
    struct Live: Codable, Sendable, Equatable {
        var keychainReadOK = false
        var keychainStatus: Int32 = 0
        var tokenShapeOK = false
        /// Valid for more than `GrokProtocol.tokenMargin` seconds.
        var tokenValid = false
        var machineIDPresent = false
        var teamIDPresent = false
        var canaryOK = false
        var canaryRows = 0
        /// A secret-free failure name (`GrokServerError.description` or an error case), when something failed.
        var failure: String?

        var ok: Bool { keychainReadOK && tokenShapeOK && tokenValid && canaryOK }
    }

    var grokBotFound = false
    var dataFolderFound = false
    var grokBotVersion = GrokProtocol.clientVersionFallback
    var versionReadable = false
    var cacheReadable = false
    var cacheProblem: String?
    var rosterRows = 0
    var bots = 0
    var groups = 0
    var cachedTranscripts = 0
    var rosterSchemaVersion: Int64?
    var transcriptSchemaVersions: [Int64] = []
    var secretsShapeOK = false
    var accounts = 0
    var machineIDStored = false
    var accountBinding = GrokPreflight.Binding.unknown.rawValue
    var keychainItemPresent = false
    var keychainProbeMs = 0
    var serverReady = false
    var live: Live?

    var ok: Bool { serverReady && rosterRows > 0 && (live?.ok ?? true) }
}

enum GrokProbe {
    /// `onKeychainRead` runs just before the live read (the command prints its notice there).
    static func run(environment: GrokImportEnvironment, live: Bool,
                    onKeychainRead: @Sendable () -> Void = {}) async -> GrokProbeReport {
        let preflight = await GrokPreflight.run(location: environment.location, passwords: environment.passwords)
        var report = GrokProbeReport(preflight)
        if live { report.live = await liveChecks(preflight, environment: environment, onKeychainRead: onKeychainRead) }
        return report
    }

    private static func liveChecks(_ preflight: GrokPreflight, environment: GrokImportEnvironment,
                                   onKeychainRead: @Sendable () -> Void) async -> GrokProbeReport.Live {
        var result = GrokProbeReport.Live()
        guard preflight.serverReady, let cache = preflight.cache,
              let data = GrokPreflight.readSecrets(environment.location.secretsFile),
              let encrypted = try? GrokSecretsFile.encryptedAccount(data: data) else {
            result.failure = "notReady"
            return result
        }
        onKeychainRead()
        var password: [UInt8]
        do { password = try await environment.gate.read(environment.passwords) } catch let error as GrokKeychainError {
            result.keychainStatus = error.status
            result.failure = "keychain"
            return result
        } catch {
            result.failure = "keychain"
            return result
        }
        result.keychainReadOK = true
        var key = (try? GrokSafeStorage.deriveKey(password: password)) ?? []
        GrokSafeStorage.zero(&password)
        defer { GrokSafeStorage.zero(&key) }
        let credentials: GrokCredentials
        do {
            credentials = try GrokImportRun.decrypt(encrypted, key: key, now: environment.now())
            result.tokenShapeOK = true
            result.tokenValid = true
        } catch GrokCredentialsError.tokenExpired {
            result.tokenShapeOK = true
            result.failure = "tokenExpired"
            return result
        } catch {
            result.failure = "signInUnreadable"
            return result
        }
        result.machineIDPresent = !credentials.machineID.isEmpty
        result.teamIDPresent = credentials.teamID != nil
        guard let agent = try? GrokImportRun.conversations(in: cache, selection: nil).first else {
            result.failure = "noConversation"
            return result
        }
        let client = GrokRPCClient(session: environment.makeSession(), credentials: credentials, clientVersion: preflight.clientVersion,
                                   appVersion: environment.appVersion, baseURL: environment.baseURL, clock: environment.clock)
        do {
            result.canaryRows = try await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil).count
            result.canaryOK = true
        } catch {
            result.failure = (error as? GrokServerError)?.description ?? "cancelled"
        }
        return result
    }
}

extension GrokProbeReport {
    init(_ preflight: GrokPreflight) {
        grokBotFound = preflight.appFound
        dataFolderFound = preflight.dataFolderFound
        grokBotVersion = preflight.clientVersion
        versionReadable = preflight.versionReadable
        if let cache = preflight.cache {
            cacheReadable = true
            rosterRows = cache.roster.count
            groups = cache.roster.filter { $0["isGroup"]?.isTruthy ?? false }.count
            bots = rosterRows - groups
            cachedTranscripts = cache.transcripts.count
            rosterSchemaVersion = cache.rosterSchemaVersion
            transcriptSchemaVersions = cache.transcriptSchemaVersions.sorted()
        }
        cacheProblem = preflight.cacheError.map { String(describing: $0) }
        secretsShapeOK = preflight.secretsShapeOK
        accounts = preflight.secrets?.accountIDs.count ?? 0
        machineIDStored = preflight.secrets?.hasMachineID ?? false
        accountBinding = preflight.binding.rawValue
        keychainItemPresent = preflight.keychainItemPresent
        keychainProbeMs = preflight.keychainMs
        serverReady = preflight.serverReady
    }
}

extension GrokKeychainError {
    var status: Int32 {
        switch self {
        case .denied(let status), .unexpected(let status): status
        case .itemMissing: errSecItemNotFound
        case .keychainLocked: -25308
        case .interactionNotAllowed: errSecInteractionNotAllowed
        }
    }
}
