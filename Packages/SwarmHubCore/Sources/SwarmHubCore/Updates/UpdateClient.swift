import Foundation

public struct UpdateConfiguration: Sendable {
    #if os(iOS)
    public static let currentPlatform = "ios"
    #else
    public static let currentPlatform = "mac"
    #endif

    /// Static host (or mirror) serving `keys.json`, `channels/<name>.json`, `bundles/<version>.json` and
    /// `blobs/sha256/<hash>` (§2.1). HTTPS only.
    public var baseURL: URL
    public var channel: String
    /// `mac` or `ios`. Apps consume data components only; box archives are never fetched here.
    public var platform: String
    /// Compatibility axes for this build: `app`, `ui_catalog`, `config_schema` (§6).
    public var versions: [String: String]
    /// Root pins compiled into the app (§2.1).
    public var pins: Data
    /// Floors of the baseline embedded in the build. Persisted floors never go below them.
    public var baseline: UpdateFloors
    /// nil: a random id generated once and persisted with the state.
    public var installID: String?
    public var revokedKeyIDs: Set<String>
    public var limits: UpdateLimits
    /// Launch, then every 6 h [A] (§3.3).
    public var interval: TimeInterval
    public var timeout: TimeInterval

    public init(baseURL: URL, channel: String = "stable", platform: String = UpdateConfiguration.currentPlatform,
                versions: [String: String], pins: Data,
                baseline: UpdateFloors = UpdateFloors(keysVersion: 0, indexSequence: 0, bundleVersion: 0),
                installID: String? = nil, revokedKeyIDs: Set<String> = [], limits: UpdateLimits = .init(),
                interval: TimeInterval = 6 * 3600, timeout: TimeInterval = 30) {
        self.baseURL = baseURL; self.channel = channel; self.platform = platform; self.versions = versions
        self.pins = pins; self.baseline = baseline; self.installID = installID
        self.revokedKeyIDs = revokedKeyIDs; self.limits = limits; self.interval = interval; self.timeout = timeout
    }
}

public struct UpdateStatus: Equatable, Sendable {
    public let current: UpdateRecord?
    public let previous: UpdateRecord?
    public let lastCheck: String?
    public let lastResult: UpdateVerdict?
    /// Non-nil: show "updates stale since <date>". Runtime is unaffected (§3.2).
    public let staleSince: String?
}

public struct UpdateCheckResult: Equatable, Sendable {
    /// Verifier verdicts, plus stage `fetch` (transport), `store` (local storage or policy) and `config`.
    public let verdict: UpdateVerdict
    public let status: UpdateStatus
}

/// P4a / CORE-PLAN §3.1, §3.3. Fetches, verifies everything through `UpdateVerifier`, and stores only
/// verified data components targeted at this app. Any failure leaves the stored bundle, the floors and
/// the app's behaviour as they were: fail closed means "do not apply", never "stop working".
public actor UpdateClient {
    public let configuration: UpdateConfiguration
    public let store: UpdateStore
    private let session: URLSession?
    private let clock: @Sendable () -> Date
    private let validate: @Sendable (UpdateRecord, [String: Data]) -> Bool
    private var running: Task<UpdateCheckResult, Never>?
    private var loop: Task<Void, Never>?

    /// `validate` is the post-apply check (§3.3), run on the staged components before the switch.
    public init(configuration: UpdateConfiguration, store: UpdateStore, session: URLSession? = nil,
                clock: @escaping @Sendable () -> Date = { Date() },
                validate: @escaping @Sendable (UpdateRecord, [String: Data]) -> Bool = { _, _ in true }) {
        self.configuration = configuration; self.store = store; self.session = session
        self.clock = clock; self.validate = validate
    }

    /// Check now (launch), then every `interval`. Call `stop()` to end the loop.
    public func start() {
        guard loop == nil else { return }
        let interval = configuration.interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.check() != nil else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Returns after a check already in flight has finished and saved its state.
    public func stop() async {
        let current = loop
        loop = nil
        current?.cancel()
        await current?.value
    }

    /// For foreground events: checks only when the last check is older than `interval`.
    public func checkIfDue() async -> UpdateCheckResult? {
        if let state = try? store.loadState(), let last = state.lastCheck,
           let date = try? Date(last, strategy: .iso8601), clock().timeIntervalSince(date) < configuration.interval {
            return nil
        }
        return await check()
    }

    /// One check at a time: a call during a running check waits for it and shares its result.
    public func check() async -> UpdateCheckResult {
        if let running { return await running.value }
        let task = Task { await self.perform() }
        running = task
        let result = await task.value
        running = nil
        return result
    }

    public func status() -> UpdateStatus {
        status(state: try? store.loadState(), now: Self.timestamp(clock()))
    }

    static func timestamp(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    // MARK: Check

    private enum Pending: Error { case manifest(UpdateLine), blob(UpdateComponent) }
    private static let maxFetches = 256

    private func perform() async -> UpdateCheckResult {
        let now = Self.timestamp(clock())
        var state: UpdateState
        do {
            state = try store.loadState() ?? UpdateState(installID: UUID().uuidString.lowercased())
        } catch {
            // Unknown floors: do not fetch or apply anything, keep what is stored.
            return UpdateCheckResult(verdict: Self.reject("store", "state_unreadable"), status: status(state: nil, now: now))
        }
        state.raise(to: configuration.baseline)
        let verdict: UpdateVerdict
        do { verdict = try await run(&state, now: now) }
        catch let failure as UpdateTransport.Failure { verdict = Self.reject("fetch", failure.reason) }
        catch is UpdateInputError { verdict = Self.reject("config", "invalid_configuration") }
        catch let failure as PolicyFailure { verdict = Self.reject("store", failure.reason) }
        catch { verdict = Self.reject("store", "storage_error") }
        state.lastCheck = now
        state.lastResult = verdict
        if ["accept", "no_update"].contains(verdict.verdict) { state.failingSince = nil }
        else if state.failingSince == nil { state.failingSince = now }
        try? store.saveState(state)
        return UpdateCheckResult(verdict: verdict, status: status(state: state, now: now))
    }

    private struct PolicyFailure: Error { let reason: String }

    private func run(_ state: inout UpdateState, now: String) async throws -> UpdateVerdict {
        let c = configuration
        guard ["mac", "ios"].contains(c.platform), matches(c.channel, "[a-z0-9-]{1,32}") else {
            throw UpdateInputError.invalidCallerInput
        }
        let transport = try UpdateTransport(base: c.baseURL, session: session, timeout: c.timeout)
        defer { transport.finish() }
        let keys = try await transport.get("keys.json", limit: c.limits.maxSignedBytes)
        let index = try await transport.get("channels/\(c.channel).json", limit: c.limits.maxSignedBytes)
        let consumer = UpdateConsumer(platform: c.platform, versions: c.versions)
        let installID = c.installID ?? state.installID
        var manifests: [String: Data] = [:], blobs: [String: Data] = [:]
        // The verifier's providers are synchronous. Each pass that needs bytes stops at the provider, the
        // bytes are fetched, and the whole chain is verified again from the pins.
        for _ in 0..<Self.maxFetches {
            var selected: String?
            let verification: UpdateVerification
            do {
                verification = try UpdateVerifier.verify(pins: c.pins, keys: keys, index: index,
                    fetchManifest: { line in
                        guard let data = manifests[line.manifestSHA256] else { throw Pending.manifest(line) }
                        selected = line.manifestSHA256
                        return data
                    },
                    fetchBlob: { component in
                        guard let data = blobs[component.sha256] else { throw Pending.blob(component) }
                        return data
                    },
                    channel: c.channel, now: now, floors: state.floors, consumer: consumer, installID: installID,
                    revokedKeyIDs: c.revokedKeyIDs, limits: c.limits)
            } catch Pending.manifest(let line) {
                manifests[line.manifestSHA256] = try await transport.get("bundles/\(line.bundleVersion).json",
                                                                         limit: c.limits.maxSignedBytes)
                continue
            } catch Pending.blob(let component) {
                blobs[component.sha256] = try await transport.get("blobs/sha256/" + component.sha256,
                                                                  limit: Int(component.size))
                continue
            }
            let verdict = verification.verdict
            switch verdict.verdict {
            case "accept":
                guard let selected, let manifest = manifests[selected] else { throw UpdateStoreError.storage }
                let snapshot = try Self.snapshot(verification, keys: keys, index: index, manifest: manifest,
                                                 manifestSHA256: selected, platform: c.platform, now: now)
                guard validate(snapshot.record, snapshot.blobs) else { throw PolicyFailure(reason: "post_apply_check_failed") }
                try store.commit(snapshot)
                state.raise(to: Self.floors(keys: keys, index: index, bundle: snapshot.record.bundleVersion))
                markFresh(&state, index: index, now: now)
            case "no_update":
                state.raise(to: Self.floors(keys: keys, index: index, bundle: 0))
                markFresh(&state, index: index, now: now)
            default:
                break
            }
            return verdict
        }
        throw UpdateTransport.Failure(reason: "fetch_limit")
    }

    private func markFresh(_ state: inout UpdateState, index: Data, now: String) {
        state.lastVerified = now
        if case .string(let expires)? = Self.signedField(index, "expires") { state.freshUntil = expires }
    }

    private func status(state: UpdateState?, now: String) -> UpdateStatus {
        UpdateStatus(current: store.record(.current), previous: store.record(.previous), lastCheck: state?.lastCheck,
                     lastResult: state?.lastResult, staleSince: state?.staleSince(now: now))
    }

    // MARK: Verified-data helpers

    static func reject(_ stage: String, _ reason: String) -> UpdateVerdict {
        UpdateVerdict(verdict: "reject", stage: stage, reason: reason)
    }

    /// Read from bytes that have just passed the verifier, so the shapes are already known to be valid.
    static func signedField(_ data: Data, _ key: String) -> JCS.Value? {
        guard case .object(let envelope)? = try? JCS.parse(data),
              case .object(let signed)? = envelope["signed"] else { return nil }
        return signed[key]
    }

    static func floors(keys: Data, index: Data, bundle: Int64) -> UpdateFloors {
        func integer(_ value: JCS.Value?) -> Int64 {
            guard case .integer(let number)? = value else { return 0 }
            return number
        }
        return UpdateFloors(keysVersion: integer(signedField(keys, "version")),
                            indexSequence: integer(signedField(index, "seq")), bundleVersion: bundle)
    }

    /// Only `config` and `ui` data components targeted at this platform are stored. The verifier already
    /// guarantees this for `mac`/`ios`; the store refuses anything else rather than trusting that alone.
    static func snapshot(_ verification: UpdateVerification, keys: Data, index: Data, manifest: Data,
                         manifestSHA256: String, platform: String, now: String) throws -> UpdateSnapshot {
        guard case .object(let signed)? = verification.manifest, case .integer(let version)? = signed["version"],
              case .array(let listed)? = signed["components"], updateDigest(manifest) == manifestSHA256,
              version == verification.verdict.bundleVersion else { throw PolicyFailure(reason: "store_policy") }
        var entries: [UpdateRecord.Component] = []
        var stored: [String: Data] = [:]
        for name in verification.verdict.apply ?? [] {
            var found: [String: JCS.Value]?
            for case .object(let candidate) in listed where candidate["name"] == .string(name) { found = candidate; break }
            guard let object = found, case .string(let kind)? = object["kind"], case .string(let contentClass)? = object["class"],
                  case .string(let componentVersion)? = object["version"], case .string(let sha256)? = object["sha256"],
                  case .integer(let size)? = object["size"], case .array(let targets)? = object["targets"],
                  contentClass == "data", ["config", "ui"].contains(kind), targets.contains(.string(platform)),
                  let blob = verification.blobs[name], Int64(blob.count) == size, updateDigest(blob) == sha256 else {
                throw PolicyFailure(reason: "store_policy")
            }
            entries.append(.init(name: name, kind: kind, contentClass: contentClass, version: componentVersion,
                                 sha256: sha256, size: size))
            stored[name] = blob
        }
        let record = UpdateRecord(bundleVersion: version, manifestSHA256: manifestSHA256, appliedAt: now,
                                  platform: platform, components: entries)
        return UpdateSnapshot(record: record, keys: keys, index: index, manifest: manifest, blobs: stored)
    }
}
