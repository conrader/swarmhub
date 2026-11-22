import Foundation
import Security

/// The standing drift check (`--grok-probe`, run after every Grok Bot update). Without `live` it never prompts and never
/// uses the network: Grok Bot's version, the cache and secrets-file shape, whether the Keychain item exists, roster counts.
/// With `live` it also makes the one Keychain read (one Allow), checks the sign-in's shape and fetches the canary page.
/// With `diagnose` (live only) it also reports what the token says about itself and, after a refusal, asks again under
/// Grok Bot's own user-agent and then under the captured client version: which of them is accepted names what moved.
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
        /// `diagnose` only: the token's own facts and one row per request variant tried.
        var token: GrokTokenFacts?
        var attempts: [Attempt]?

        var ok: Bool { keychainReadOK && tokenShapeOK && tokenValid && canaryOK }
    }

    /// One request variant of the diagnose run: `swarmhub` (what an import sends), `grok-bot-user-agent`, `captured-version`.
    struct Attempt: Codable, Sendable, Equatable {
        var variant: String
        var status: Int?
        var connectCode: String?
        var message: String?
        var rows: Int?
        var failure: String?
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
    static func run(environment: GrokImportEnvironment, live: Bool, diagnose: Bool = false,
                    onKeychainRead: @Sendable () -> Void = {}) async -> GrokProbeReport {
        let preflight = await GrokPreflight.run(location: environment.location, passwords: environment.passwords)
        var report = GrokProbeReport(preflight)
        if live {
            report.live = await liveChecks(preflight, environment: environment, diagnose: diagnose, onKeychainRead: onKeychainRead)
        }
        return report
    }

    private static func liveChecks(_ preflight: GrokPreflight, environment: GrokImportEnvironment, diagnose: Bool,
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
        // Read again now that the wait for macOS is over: Grok Bot may have renewed its sign-in meanwhile.
        let current = GrokPreflight.readSecrets(environment.location.secretsFile)
            .flatMap { try? GrokSecretsFile.encryptedAccount(data: $0) } ?? encrypted
        if diagnose, let token = try? GrokSafeStorage.decryptText(current.accessToken, key: key) {
            result.token = GrokCredentials.tokenFacts(token, now: environment.now())
        }
        let credentials: GrokCredentials
        do {
            credentials = try GrokImportRun.decrypt(current, key: key, now: environment.now())
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
        guard diagnose else {
            do {
                result.canaryRows = try await client.listEntries(agentID: agent, limit: 1, beforeSeq: nil).count
                result.canaryOK = true
            } catch {
                result.failure = (error as? GrokServerError)?.description ?? "cancelled"
            }
            return result
        }
        // Stops at the first variant Grok accepts. Only the first is what an import sends, so only it sets `canaryOK`.
        let variants: [(name: String, userAgent: String?, clientVersion: String?)] = [
            ("swarmhub", nil, nil),
            ("grok-bot-user-agent", GrokProtocol.grokBotUserAgent(clientVersion: preflight.clientVersion), nil),
            ("captured-version", nil, GrokProtocol.capturedVersion),
        ]
        var attempts: [GrokProbeReport.Attempt] = []
        for variant in variants {
            var attempt = GrokProbeReport.Attempt(variant: variant.name)
            do {
                let outcome = try await client.diagnoseList(agentID: agent, userAgent: variant.userAgent,
                                                            clientVersion: variant.clientVersion)
                attempt.status = outcome.status
                attempt.connectCode = outcome.connectCode
                attempt.message = outcome.message
                attempt.rows = outcome.rows
            } catch {
                attempt.failure = (error as? GrokServerError)?.description ?? "cancelled"
            }
            attempts.append(attempt)
            if attempt.status == 200 || attempt.failure != nil { break }
        }
        result.attempts = attempts
        if let first = attempts.first {
            result.canaryOK = first.status == 200 && first.rows != nil
            result.canaryRows = first.rows ?? 0
            if !result.canaryOK {
                result.failure = first.failure ?? "list HTTP \(first.status ?? 0)" + (first.connectCode.map { " \($0)" } ?? "")
            }
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
