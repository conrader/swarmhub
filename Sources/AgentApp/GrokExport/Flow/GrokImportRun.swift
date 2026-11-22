import Foundation

/// The pipeline the `--grok-fetch` command and the sheet share: preflight with no prompt →
/// [full] the one Keychain read → derive the key, zero the password → decrypt the three values, shape checks, `exp` more
/// than 60 s away → canary (the newest page of the first conversation must decode before anything is written) → per
/// conversation, bots first and groups last: fetch → merge with the cache → map → redact → build → commit → report row.
///
/// Each conversation is committed on its own, so finished bots stay whatever happens later. Network trouble and an
/// expired or refused sign-in pause the run (resumable, the sign-in or key held in memory for at most ten minutes); other
/// 4xx and `protocolChanged` stop it. No resume state is written: a later run starts over and merges by entry id.
@MainActor final class GrokImportRun {
    enum Event: Sendable {
        /// Printed or shown before the read that may raise the macOS dialog.
        case keychainReadComing
        case conversation(index: Int, total: Int, name: String, sourceID: String)
        case page(pages: Int, oldestSeq: Int64)
        /// Fetching is over for this conversation: merge, map, redact and commit.
        case saving(sourceID: String)
        case committed(GrokImportRunRow)
        /// Grok's service stopped All history (`fallsBackToRecent`): for every conversation still queued (`wholeRun`),
        /// or for the one being fetched only.
        case fellBack(GrokServerError, wholeRun: Bool)
    }

    let store: AppStore
    let environment: GrokImportEnvironment
    private(set) var options: GrokImportOptions
    private(set) var state: GrokImportRunState = .idle
    private(set) var preflight: GrokPreflight?
    private(set) var rows: [GrokImportRunRow] = []
    /// Keychain data reads started by this run (the brief allows one per import, plus one after a 401 or a lapsed hold).
    private(set) var keychainReads = 0
    var onEvent: ((Event) -> Void)?
    let holder: GrokSecretHolder

    /// Why All history gave way to the recent messages on this Mac for every conversation still queued; nil while Grok
    /// answers, and always without the option.
    private(set) var fallback: GrokServerError?
    /// Conversations in a row that Grok's service stopped on their own: two mean it is not about one conversation.
    private var conversationStops = 0
    /// The conversation being fetched (nil at the canary), and the one a 401 pause was last taken in.
    private var fetching: String?
    private var signInPauseIn: String?
    private var queue: [String]?
    private var progress: GrokFetchProgress?
    private var canaryPassed = false
    private var client: GrokRPCClient?
    private var requestsBefore = 0
    private var task: Task<Void, Never>?

    init(store: AppStore, environment: GrokImportEnvironment, options: GrokImportOptions = .init()) {
        self.store = store
        self.environment = environment
        self.options = options
        holder = GrokSecretHolder(hold: environment.hold, clock: environment.clock)
    }

    /// After Cancel: part of a conversation was fetched and `importWhatWasFetched()` can commit it.
    var hasFetchedPart: Bool { progress != nil }

    /// Every request sent to Grok so far in this run, retries and blob GETs included.
    func requestCount() async -> Int { requestsBefore + (await client?.requestCount ?? 0) }

    /// The next step needs the macOS dialog: full mode and neither a sign-in nor a key is held.
    func willAskMacOS() async -> Bool {
        guard options.mode == .full, await holder.currentCredentials() == nil else { return false }
        return await !holder.hasHeldKey
    }

    // MARK: Actions

    /// Starts a new run. Refused while this run is active or another Keychain read is pending.
    @discardableResult func start(_ options: GrokImportOptions? = nil) async -> GrokImportRunState {
        guard !state.isActive else { return state }
        if environment.gate.isReading { state = .stopped(.keychainReadInFlight); return state }
        if let options { self.options = options }
        await holder.forget()
        rows = []; queue = nil; progress = nil; canaryPassed = false; client = nil; requestsBefore = 0; preflight = nil
        fallback = nil; conversationStops = 0; fetching = nil; signInPauseIn = nil
        return await perform()
    }

    /// After a network pause: continue the interrupted conversation from its cursor with the sign-in still in memory.
    @discardableResult func retryRemaining() async -> GrokImportRunState {
        guard state.isPaused else { return state }
        return await perform()
    }

    /// After an expired sign-in: re-read `sand-secrets.json` and decrypt with the held key (no second prompt).
    @discardableResult func checkAgain() async -> GrokImportRunState { await retryRemaining() }

    /// Cancel stops after the in-flight request; a pending Keychain wait is abandoned (its late result is dropped).
    func cancel() {
        if let task { task.cancel(); return }
        guard state.isPaused else { return }
        state = .cancelled
        Task { await holder.forget(); await dropClient() }
    }

    /// "Forget sign-in": the key and the decrypted values go now; the next step announces a new macOS prompt.
    func forgetSignIn() async {
        await holder.forget()
        await dropClient()
    }

    /// Drops the held sign-in once a pause outlived its hold (the sheet calls this on a timer).
    func expireHoldIfDue() async { if await holder.expireIfDue() { await dropClient() } }

    /// The client holds its own copy of the sign-in, so it goes whenever the holder forgets; its requests stay counted.
    private func dropClient() async {
        // Taken out first: a second call that overlaps this one across the await must not count the client again.
        guard let dropped = client else { return }
        client = nil
        requestsBefore += await dropped.requestCount
    }

    /// After Cancel: commit what was fetched for the interrupted conversation, marked incomplete.
    @discardableResult func importWhatWasFetched() async -> GrokImportRunState {
        guard state == .cancelled, let progress, let cache = preflight?.cache else { return state }
        self.progress = nil
        _ = await commit(progress.sourceID, cache: cache, fetched: progress.result)
        return state
    }

    // MARK: Driver

    private func perform() async -> GrokImportRunState {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Importing Grok Bot history")
        let running = Task { await self.drive() }
        task = running
        await running.value
        task = nil
        ProcessInfo.processInfo.endActivity(activity)
        switch state {
        case .finished, .stopped, .cancelled, .idle:
            await holder.forget()
            await dropClient()
        case .paused: await holder.pause()
        case .preflighting, .awaitingMacOS, .running: break
        }
        return state
    }

    private func drive() async {
        if preflight == nil {
            state = .preflighting
            preflight = await GrokPreflight.run(location: environment.location, passwords: environment.passwords)
        }
        guard store.persistenceEnabled else { return stop(.persistenceDisabled) }
        guard let cache = preflight?.cache else { return stop(.cache(preflight?.cacheError ?? .notFound)) }
        if queue == nil {
            do { queue = try Self.conversations(in: cache, selection: options.selection).filter { !options.excludedSourceIDs.contains($0) } } catch let error as GrokImportRunError {
                return stop(error)
            } catch { return stop(.cache(.unrecognisedShape)) }
        }
        if options.mode == .full, fallback == nil {
            if let reason = preflight?.cacheOnlyReason { return stop(reason) }
            var ready = await ensureSignIn()
            if ready { ready = await passCanary() }
            if !ready { guard await fellBack(atCanary: true) else { return } }
        }
        state = .running
        let total = rows.count + (queue?.count ?? 0)
        while let id = queue?.first {
            if Task.isCancelled { state = .cancelled; return }
            let name = cache.roster.first { $0["id"]?.stringValue == id }?["name"]?.stringValue ?? "Grok bot"
            onEvent?(.conversation(index: rows.count + 1, total: total, name: name, sourceID: id))
            var fetched: GrokHistoryFetcher.Result?
            if options.mode == .full, fallback == nil {
                fetching = id
                if let result = await fetch(id) {
                    fetched = result
                    conversationStops = 0
                } else if await fellBack(atCanary: false) {
                    // What was fetched of this conversation before Grok stopped is kept; it commits as incomplete.
                    if let part = progress, part.sourceID == id, !part.result.entries.isEmpty { fetched = part.result }
                    progress = nil
                } else { return }
                fetching = nil
            }
            onEvent?(.saving(sourceID: id))
            // All history was asked for and nothing came from Grok: the cache's lines are saved, the chat is not done.
            guard await commit(id, cache: cache, fetched: fetched, wantedMore: options.mode == .full && fetched == nil) else { return }
            queue?.removeFirst()
        }
        state = .finished
    }

    private func stop(_ error: GrokImportRunError) { state = .stopped(error) }

    /// A stop that came from Grok's service does not end a run that may fall back. A stop at the canary, a refusal of
    /// the sign-in or this app's own request ceiling sends every conversation still queued to the cache and forgets the
    /// sign-in. A stop inside one conversation (a page this app cannot read, a refused request) sends only that one
    /// there and All history goes on with the next, unless the one before it was stopped too. Stops of this Mac's own
    /// making (Keychain, store) stay stops.
    private func fellBack(atCanary: Bool) async -> Bool {
        guard options.fallsBackToRecent, case .stopped(.server(let error)) = state else { return false }
        conversationStops += 1
        let wholeRun = atCanary || error.endsFullHistory || conversationStops >= 2
        if wholeRun {
            fallback = error
            await holder.forget()
            await dropClient()
        }
        onEvent?(.fellBack(error, wholeRun: wholeRun))
        state = .running
        return true
    }

    // MARK: Sign-in

    /// Makes sure the three values are in memory: already held, decrypted with a held key (Check again), or read once
    /// from the Keychain. Sets the pause or stop state and returns false when the run cannot go on.
    private func ensureSignIn() async -> Bool {
        if await holder.currentCredentials() != nil { await holder.resume(); return true }
        await dropClient()
        guard let data = GrokPreflight.readSecrets(environment.location.secretsFile),
              let encrypted = try? GrokSecretsFile.encryptedAccount(data: data) else {
            stop(.credentials(.noSignedInAccount)); return false
        }
        let now = environment.now()
        if let held = await holder.withHeldKey({ key in Result { try Self.decrypt(encrypted, key: key, now: now) } }) {
            return await settle(held, key: nil)
        }
        if Task.isCancelled { state = .cancelled; return false }
        onEvent?(.keychainReadComing)
        state = .awaitingMacOS
        keychainReads += 1
        var password: [UInt8]
        do { password = try await environment.gate.read(environment.passwords) } catch is CancellationError {
            state = .cancelled; return false
        } catch let error as GrokKeychainError {
            stop(.keychain(error)); return false
        } catch let error as GrokImportRunError {
            stop(error); return false
        } catch { stop(.signInUnreadable); return false }
        if Task.isCancelled { GrokSafeStorage.zero(&password); state = .cancelled; return false }
        var key: [UInt8]
        do { key = try GrokSafeStorage.deriveKey(password: password) } catch {
            GrokSafeStorage.zero(&password); stop(.signInUnreadable); return false
        }
        GrokSafeStorage.zero(&password)
        defer { GrokSafeStorage.zero(&key) }
        // The wait for macOS has no limit and Grok Bot renews its sign-in meanwhile: read the file and the clock again.
        guard let renewed = GrokPreflight.readSecrets(environment.location.secretsFile),
              let current = try? GrokSecretsFile.encryptedAccount(data: renewed) else {
            stop(.credentials(.noSignedInAccount)); return false
        }
        // The account the preflight bound to the cache must still be the one signed in.
        guard current.activeAccountID == encrypted.activeAccountID else { stop(.credentials(.accountMismatch)); return false }
        let answered = environment.now()
        return await settle(Result { try Self.decrypt(current, key: key, now: answered) }, key: key)
    }

    /// `key` is the freshly derived one (nil when the held key was used): kept only for an expired token.
    private func settle(_ outcome: Result<GrokCredentials, any Error>, key: [UInt8]?) async -> Bool {
        switch outcome {
        case .success(let credentials):
            await holder.store(credentials)
            return true
        case .failure(GrokCredentialsError.tokenExpired):
            if let key { await holder.holdKey(key) }
            state = .paused(.tokenExpired)
            return false
        case .failure(let error as GrokCredentialsError):
            stop(.credentials(error)); return false
        case .failure:
            stop(.signInUnreadable); return false
        }
    }

    nonisolated static func decrypt(_ encrypted: GrokSecretsFile.EncryptedAccount, key: [UInt8], now: Date) throws -> GrokCredentials {
        try GrokCredentials.decrypt(from: encrypted, key: key, now: now, margin: GrokProtocol.tokenMargin)
    }

    // MARK: Server

    private func currentClient() async -> GrokRPCClient? {
        if let client { return client }
        guard let credentials = await holder.currentCredentials() else { return nil }
        let made = GrokRPCClient(session: environment.makeSession(), credentials: credentials,
                                 clientVersion: preflight?.clientVersion ?? GrokProtocol.clientVersionFallback,
                                 appVersion: environment.appVersion, baseURL: environment.baseURL, clock: environment.clock)
        client = made
        return made
    }

    /// The newest page of a conversation must decode before anything is written. The canary is a conversation this Mac
    /// holds entries of, so its newest page cannot be empty unless it was cleared on Grok's side; when a second such
    /// conversation also answers with no row, it is an answer this app cannot read.
    private func passCanary() async -> Bool {
        guard !canaryPassed, let queue, let first = queue.first else { return true }
        guard let client = await currentClient() else { stop(.signInUnreadable); return false }
        let cached = queue.filter { preflight?.cache?.transcripts[$0]?.isEmpty == false }
        let candidates = cached.isEmpty ? [first] : Array(cached.prefix(2))
        do {
            var empty = 0
            for id in candidates {
                let rows = try await client.listEntries(agentID: id, limit: 1, beforeSeq: nil)
                if !rows.isEmpty { break }
                empty += 1
            }
            if empty == 2 {
                stop(.server(GrokServerError(.protocolChanged, kind: .list, errorType: "EmptyCanary")))
                return false
            }
            canaryPassed = true
            return true
        } catch let error as GrokServerError {
            await serverFailed(error); return false
        } catch { state = .cancelled; return false }
    }

    /// Pages one conversation, resuming the interrupted one from its cursor. Nil when the run paused, stopped or was
    /// cancelled (the fetched part stays in `progress`).
    private func fetch(_ id: String) async -> GrokHistoryFetcher.Result? {
        guard let client = await currentClient() else { stop(.signInUnreadable); return nil }
        var current = progress?.sourceID == id ? progress! : GrokFetchProgress(sourceID: id)
        let fetcher = GrokHistoryFetcher(client: client)
        let next = await fetcher.fetchOlder(agentID: id, beforeSeq: current.result.nextBeforeSeq) { [weak self] pages, oldest in
            Task { @MainActor in self?.onEvent?(.page(pages: pages, oldestSeq: oldest)) }
        }
        current.absorb(next)
        progress = current
        switch next.stop {
        case .failed(let error)?:
            await serverFailed(error); return nil
        case .cancelled?:
            state = .cancelled; return nil
        case .pageCeiling?, nil:
            progress = nil
            return current.result
        }
    }

    /// A 401 drops the sign-in. One Grok had accepted earlier ran out mid-run, so the run pauses and Continue reads the
    /// renewed one (macOS asks again). One refused on its first request would be refused again whatever macOS is asked,
    /// so the run stops with the refusal. Network trouble pauses with the sign-in held; anything else stops the run.
    private func serverFailed(_ error: GrokServerError) async {
        switch error.reason {
        case .signInInvalid:
            let accepted = (await client?.successfulRPCs ?? 0) > 0
            // A sign-in that runs out is renewed once per conversation. A second 401 in the same one is about something
            // this sign-in may not do there (a file read, say), and asking macOS again would only loop.
            let repeated = fetching != nil && signInPauseIn == fetching
            await dropClient()
            await holder.forget()
            if accepted, !repeated {
                signInPauseIn = fetching
                state = .paused(.signInInvalid)
            } else {
                state = .stopped(.server(error))
            }
        case .network, .unavailable:
            state = .paused(.network(error))
        case .rejected where error.isTransientRefusal:
            // Too many requests or a server error: nothing is wrong with the run, so it waits for Retry remaining.
            state = .paused(.network(error))
        default:
            state = .stopped(.server(error))
        }
    }

    // MARK: Commit

    /// Merge with the cache → map → redact → build (off the main actor) → commit this one conversation. A local error
    /// (unreadable archive, mapping failure) skips it with a secret-free reason; a store that cannot save stops the run.
    private func commit(_ id: String, cache: GrokCache, fetched: GrokHistoryFetcher.Result?, wantedMore: Bool = false) async -> Bool {
        let cached = cache.transcripts[id] ?? [], roster = cache.roster
        let (built, merge) = await Task.detached(priority: .userInitiated) { () -> (GrokBundleV1?, GrokHistoryMerge.Result?) in
            let merge = fetched.map { GrokHistoryMerge.merge(cached: cached, fetched: $0) }
            let entries = merge?.entries ?? cached
            var gaps: [[Int64]]?
            switch merge?.coverage {
            case .complete?: gaps = []
            case .serverGaps(let ranges)?: gaps = ranges
            case .incomplete?, nil: gaps = nil
            }
            let result = GrokBundleBuilder.build(roster: roster, transcripts: [id: entries], gaps: gaps.map { [id: $0] })
            return (result.bundles.first { $0.sourceID == id }, merge)
        }.value
        let rosterRow = roster.first { $0["id"]?.stringValue == id }
        var row = GrokImportRunRow(sourceID: id, name: built?.name ?? rosterRow?["name"]?.stringValue ?? "Grok bot",
                                   isGroup: built?.isGroup ?? rosterRow?["isGroup"]?.isTruthy ?? false,
                                   status: .done, coverage: .cacheOnly)
        row.cachedEntries = cached.count
        row.fetchedEntries = fetched?.entries.count ?? 0
        row.stats = fetched?.stats ?? .init()
        switch merge?.coverage {
        case .complete?: row.coverage = .complete
        case .serverGaps?: row.coverage = .serverGaps
        case .incomplete(let stoppedAt, _)?: row.coverage = .incomplete; row.status = .incomplete; row.stoppedAtSeq = stoppedAt
        case nil: if wantedMore { row.status = .incomplete }
        }
        if let unresolved = merge?.unresolvedSequences, !unresolved.isEmpty {
            row.reason = "\(unresolved.count) listed messages had no readable body. Retry to fetch them again."
        }
        let gaps = merge?.summary.gaps ?? []
        row.gapRanges = gaps.count
        row.missingSeqs = gaps.reduce(0) { $0 + ($1[1] - $1[0] + 1) }
        guard let built else {
            row.status = .skipped
            row.reason = "The conversation could not be mapped."
            return record(row)
        }
        row.messages = built.messages.count
        row.droppedByKind = built.statistics.droppedByKind
        row.redactions = built.redactions.values.reduce(0, +)
        row.hiddenMessages = built.statistics.hiddenMessages
        let before = store.grokArchiveLines(sourceID: id)
        do {
            let policy = GrokImportPolicy.inApp(refreshIdentity: options.refreshIdentity)
            let imported = try await store.importGrokBundles([GrokBotBundle(built)], policy: policy, destination: options.destination,
                                                             settledFetchedSequences: [id: merge?.settledFetchedSequences ?? []])
            row.archiveLines = imported.first?.historyCount ?? 0
            row.created = imported.first?.created
            row.addedLines = max(0, row.archiveLines - before)
        } catch let error as GrokImportError {
            row.status = .skipped
            row.reason = error.errorDescription
            _ = record(row)
            stop(.local(error))
            return false
        } catch {
            row.status = .skipped
            row.reason = (error as? LocalizedError)?.errorDescription ?? "The conversation could not be saved."
        }
        return record(row)
    }

    private func record(_ row: GrokImportRunRow) -> Bool {
        rows.append(row)
        onEvent?(.committed(row))
        return true
    }

    /// The conversations to import, bots first in roster order, groups last. A selected group brings its members.
    nonisolated static func conversations(in cache: GrokCache, selection: [String]?) throws -> [String] {
        let rows = cache.roster.filter { $0["id"]?.stringValue != nil }
        var chosen = Set<String>()
        if let selection {
            var unknown = 0
            for wanted in selection.map({ $0.trimmingCharacters(in: .whitespaces) }) where !wanted.isEmpty {
                guard let row = rows.first(where: { $0["id"]?.stringValue == wanted })
                        ?? rows.first(where: { ($0["name"]?.stringValue ?? "").caseInsensitiveCompare(wanted) == .orderedSame })
                else { unknown += 1; continue }
                chosen.insert(row["id"]!.stringValue!)
                (row["memberIds"]?.arrayValue ?? []).compactMap(\.stringValue).forEach { chosen.insert($0) }
            }
            if unknown > 0 { throw GrokImportRunError.unknownBots(unknown) }
        }
        let picked = rows.filter { selection == nil || chosen.contains($0["id"]!.stringValue!) }
        let isGroup = { (row: [String: JSONValue]) in row["isGroup"]?.isTruthy ?? false }
        return (picked.filter { !isGroup($0) } + picked.filter(isGroup)).map { $0["id"]!.stringValue! }
    }
}
