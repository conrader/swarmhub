import AppKit
import Foundation

/// The import sheet's state: one `GrokImportRun` per sheet session, the same pipeline as
/// `--grok-fetch`. Nothing is read from the Keychain before the user presses Continue on the Permission step, and at
/// most one read happens per sheet session (a pause and Retry included); closing the sheet is Cancel and forgets the
/// sign-in. Published state is names, counts and secret-free reasons only.
@MainActor final class GrokImportCoordinator: ObservableObject {
    enum Step: Equatable {
        case idle, scanning, found
        /// The explanation before the one macOS dialog (Full mode only).
        case permission
        case awaitingMacOS(since: Date)
        case running
        case paused(GrokImportPause)
        case finished
        /// Cancelled mid-run; "Import what was fetched" commits the interrupted conversation as incomplete.
        case cancelled
        case failed(GrokImportRunError)
    }

    @Published var step: Step = .idle
    @Published var availability: GrokAvailability?
    @Published var grokVersion: String?
    @Published var items: [GrokFoundItem] = []
    @Published var selected: Set<String> = []
    @Published var mode: GrokImportMode = .full
    @Published var refreshIdentity = false
    @Published var destinationPlan: GrokDestination?
    @Published private(set) var exportBundles: [GrokBotBundle]?
    let requiresTestedHost: Bool
    @Published var progress: [GrokProgressRow] = []
    /// Why this run imported the recent messages although All history was chosen; nil while Grok answers.
    @Published var fallback: GrokServerError?
    /// The last such stop, from an earlier sheet session: the sheet then opens on Recent messages.
    @Published var lastRefusal: GrokRefusalNote?
    @Published var outcomes: [GrokImportOutcome] = []
    @Published var requests = 0
    @Published var elapsedSeconds = 0
    /// True while a Keychain read is pending anywhere in the app (Continue stays disabled until it returns).
    @Published var keychainBusy = false
    /// `sand-secrets.json` is over a day old and Grok Bot is not running: the sign-in may have expired.
    @Published var signInMayBeStale = false
    /// The sign-in (or, for an expired token, the key) is held in memory during a pause.
    @Published var holdsSignIn = false

    let store: AppStore
    let environment: GrokImportEnvironment
    private let isGrokRunning: @Sendable () -> Bool
    private(set) var run: GrokImportRun?
    private var preflight: GrokPreflight?
    /// Every conversation committed in this sheet session, in import order (a re-commit replaces its row).
    private(set) var committedRows: [GrokImportRunRow] = []
    private var current: String?
    private var driver: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var keychainWatch: Task<Void, Never>?
    /// "Retry remaining" on the Done step: the next fresh run adds to this session's committed rows.
    private var keepCommittedRows = false
    /// Elapsed counts running time only: a pause freezes it, a resume continues it, a fresh run starts it at zero.
    private var elapsedBefore: Duration = .zero
    private var runningSince: ContinuousClock.Instant?

    init(store: AppStore, environment: GrokImportEnvironment, destination: GrokDestination? = nil, requiresTestedHost: Bool = false,
         isGrokRunning: @escaping @Sendable () -> Bool = { GrokImportCoordinator.grokBotIsRunning() }) {
        self.store = store
        self.destinationPlan = destination
        self.requiresTestedHost = requiresTestedHost
        self.environment = environment
        self.isGrokRunning = isGrokRunning
    }

    nonisolated static func grokBotIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: GrokProtocol.bundleIdentifier).isEmpty
    }

    /// A Herdr server is set up, and the first one's name: new bots run there.
    var hasServer: Bool { testedServer != nil || (!requiresTestedHost && store.herdrConfigured) }
    var testedServer: HerdrServer? {
        guard let plan = destinationPlan, let saved = store.herdrServer(id: plan.serverID),
              plan.testedHost.map({ $0 == saved }) ?? true else { return nil }
        return saved
    }
    var canProceed: Bool { !selected.isEmpty && availability?.canImport == true && (!requiresTestedHost || testedServer != nil) }
    var serverName: String { testedServer?.name ?? store.herdrServers[0].name }
    var historyDirectory: URL { store.grokHistory.directory }

    /// Grok Bot's id of the signed-in account, as the last scan read it.
    var accountID: String? { preflight?.secrets?.activeAccountID }
    var selectedItems: [GrokFoundItem] { items.filter { selected.contains($0.id) } }
    /// "At least N read requests, about T s" for the Full mode line: one canary plus the pages, 0.5 s apart.
    var requestEstimate: (requests: Int, seconds: Int) {
        let pages = selectedItems.map(\.minimumRequests).reduce(0, +)
        let requests = selectedItems.isEmpty ? 0 : pages + 1
        return (requests, max(1, Int((Double(requests) * 0.6).rounded(.up))))
    }

    // MARK: Found

    /// Tier 2: the no-prompt preflight (cache, account binding, secrets-file structure, attributes-only Keychain query).
    func scan() async {
        guard driver == nil else { return }
        step = .scanning
        let found = await GrokPreflight.run(location: environment.location, passwords: environment.passwords)
        preflight = found
        grokVersion = found.versionReadable ? found.clientVersion : nil
        availability = GrokLocator.availability(found, persistenceEnabled: store.persistenceEnabled)
        exportBundles = nil
        items = found.cache.map(makeItems) ?? []
        planNewBotIDs()
        selected = Set(items.map(\.id))
        lastRefusal = GrokRefusalNote.load(store.defaults, now: environment.now(), account: found.secrets?.activeAccountID)
        mode = availability == .ready && lastRefusal == nil ? .full : .recent
        signInMayBeStale = secretsOlderThanADay() && !isGrokRunning()
        watchKeychain()
        step = .found
    }

    /// Ticking a group ticks its members; unticking a group leaves them. A ticked group always brings its members
    /// (`GrokImportRun.conversations`), so unticking a member unticks the groups it belongs to.
    func toggle(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        if selected.contains(id) {
            selected.remove(id)
            items.filter { $0.isGroup && $0.memberIDs.contains(id) }.forEach { selected.remove($0.id) }
            return
        }
        selected.insert(id)
        if item.isGroup { item.memberIDs.filter { member in items.contains { $0.id == member } }.forEach { selected.insert($0) } }
    }

    /// Found → Permission (Full mode, when macOS would be asked) or straight to importing.
    func proceed() async {
        guard canProceed else { return }
        if exportBundles != nil { beginExport(); return }
        if mode == .full, availability == .ready, await currentRun().willAskMacOS() { step = .permission; watchKeychain(); return }
        begin(fresh: true) { run, options in await run.start(options) }
    }

    // MARK: Permission and running

    /// The only place the macOS dialog can start: the user pressed Continue on the Permission step.
    func continueToMacOS() {
        guard step == .permission || isRetryAfterDeny, !environment.gate.isReading else { return }
        begin(fresh: true) { run, options in await run.start(options) }
    }

    /// Deny, a locked keychain or an unreadable sign-in: import the recent messages kept on this Mac instead.
    func recentOnly() {
        mode = .recent
        begin(fresh: true) { run, options in await run.start(options) }
    }

    /// A network pause, or a 401 pause (macOS will ask again; the screen said so).
    func retryRemaining() { begin(fresh: false) { run, _ in await run.retryRemaining() } }

    /// An expired sign-in: re-read Grok Bot's sign-in file with the held key (no second prompt).
    func checkAgain() { begin(fresh: false) { run, _ in await run.checkAgain() } }

    func forgetSignIn() async {
        await run?.forgetSignIn()
        holdsSignIn = false
    }

    /// Stop after the in-flight request; a pending Keychain wait is abandoned. Finished bots stay.
    func cancel() {
        if exportBundles != nil { driver?.cancel(); return }
        guard let run else { return }
        run.cancel()
        guard driver == nil, step.isPaused else { return }
        driver = Task { [weak self] in await self?.settle(.cancelled) }
    }

    /// The conversations of the last run that did not finish (incomplete, skipped, failed, or never reached).
    var unfinishedIDs: [String] {
        guard step == .finished || step == .cancelled || step.isFailed else { return [] }
        return progress.filter { $0.status != .done }.map(\.id)
    }

    /// "Retry remaining" on the Done step: a new run over the unfinished conversations only. The sign-in was forgotten
    /// when the run ended, so Full mode goes through the Permission step again before macOS is asked.
    func retryUnfinished() async {
        let ids = unfinishedIDs
        guard driver == nil, !ids.isEmpty else { return }
        selected = Set(ids)
        keepCommittedRows = true
        await proceed()
    }

    /// After Cancel: commit the interrupted conversation as incomplete.
    func importWhatWasFetched() {
        guard step == .cancelled else { return }
        begin(fresh: false) { run, _ in
            let state = await run.importWhatWasFetched()
            return state == .cancelled ? .finished : state
        }
    }

    var canImportWhatWasFetched: Bool { step == .cancelled && run?.hasFetchedPart == true }

    /// Back to the checklist (untick a failing bot and run again); never while something is running.
    func back() {
        guard driver == nil else { return }
        keepCommittedRows = false
        step = .found
    }

    /// The sheet closed: Cancel, then forget every secret.
    func dismiss() async {
        cancel()
        await driver?.value
        await run?.forgetSignIn()
        stopTicker()
        keychainWatch?.cancel()
        keychainWatch = nil
        holdsSignIn = false
    }

    /// Tests and the sheet: wait for the current action to settle.
    func settled() async { await driver?.value }

    /// A sign-in or Keychain failure (Deny, locked, missing, still pending): Try again starts a new run.
    var isRetryAfterDeny: Bool {
        if case .failed(let error) = step { return error.isSignInStep } else { return false }
    }

    private func currentRun() -> GrokImportRun {
        if let run { return run }
        let made = GrokImportRun(store: store, environment: environment)
        made.onEvent = { [weak self] event in self?.handle(event) }
        run = made
        return made
    }

    private func options() -> GrokImportOptions {
        let ids = items.map(\.id).filter(selected.contains)
        return GrokImportOptions(mode: mode, selection: ids.count == items.count ? nil : ids, refreshIdentity: refreshIdentity, destination: destinationPlan,
            excludedSourceIDs: keepCommittedRows ? Set(committedRows.filter { $0.status == .done }.map(\.sourceID)) : [],
            fallsBackToRecent: true)
    }

    /// `fresh`: a new run (Start, Try again, Recent only) rather than a continuation of the paused or cancelled one.
    private func begin(fresh: Bool, _ action: @escaping @MainActor (GrokImportRun, GrokImportOptions) async -> GrokImportRunState) {
        guard driver == nil else { return }
        let run = currentRun(), options = options()
        if fresh {
            // A retry of the unfinished chats keeps saying why the others came from the cache.
            if !keepCommittedRows { fallback = nil }
            resetProgress(options)
            if !keepCommittedRows { committedRows = []; outcomes = [] }
            keepCommittedRows = false
        }
        step = .running
        startTicker(fresh: fresh)
        driver = Task { [weak self] in
            let state = await action(run, options)
            await self?.settle(state)
        }
    }

    private func resetProgress(_ options: GrokImportOptions) {
        guard let cache = preflight?.cache else { progress = []; return }
        let order = (try? GrokImportRun.conversations(in: cache, selection: options.selection)) ?? []
        progress = order.filter { !options.excludedSourceIDs.contains($0) }.compactMap { id in
            items.first { $0.id == id }.map { GrokProgressRow(id: id, name: $0.name, isGroup: $0.isGroup, newestSeq: $0.newestCachedSeq) }
        }
        current = nil
    }

    private func settle(_ state: GrokImportRunState) async {
        driver = nil
        await tick()
        switch state {
        case .finished:
            await refreshOutcomes()
            selectImportedMainBotIfNeeded()
            // All history demonstrably worked: at least one chat of this run came from Grok.
            if mode == .full, fallback == nil, exportBundles == nil, committedRows.contains(where: { $0.coverage != .cacheOnly }) {
                forgetRefusal()
            }
            step = .finished
            stopTicker()
        case .paused(let pause):
            mark(current, .paused)
            freezeElapsed()
            step = .paused(pause)
        case .stopped(let error):
            if let current, progress.first(where: { $0.id == current })?.status.isActive == true {
                mark(current, .failed(error.errorDescription ?? "stopped"))
            }
            step = .failed(error)
            await refreshOutcomes()
            stopTicker()
        case .cancelled:
            step = .cancelled
            await refreshOutcomes()
            stopTicker()
        case .idle, .preflighting, .awaitingMacOS, .running:
            break
        }
    }

    private func handle(_ event: GrokImportRun.Event) {
        switch event {
        case .keychainReadComing:
            step = .awaitingMacOS(since: Date())
        case .conversation(_, _, _, let id):
            current = id
            step = .running
            mark(id, mode == .full && fallback == nil ? .fetching : .readingCache)
        case .page(let pages, let oldest):
            guard let current, let index = progress.firstIndex(where: { $0.id == current }),
                  progress[index].status == .fetching else { return }
            progress[index].pages = pages
            progress[index].oldestSeq = oldest
        case .saving(let id):
            mark(id, .saving)
        case .fellBack(let error, let wholeRun):
            if wholeRun { fallBack(error) }
        case .committed(let row):
            if let index = committedRows.firstIndex(where: { $0.sourceID == row.sourceID }) {
                // A retry that got nothing from Grok does not replace the row of an earlier partial fetch.
                if !(committedRows[index].coverage == .incomplete && row.coverage == .cacheOnly) { committedRows[index] = row }
            } else { committedRows.append(row) }
            switch row.status {
            case .done: mark(row.sourceID, .done)
            case .incomplete: mark(row.sourceID, .incomplete)
            case .skipped: mark(row.sourceID, .skipped(row.reason ?? "not imported"))
            }
        }
    }

    private func mark(_ id: String?, _ status: GrokProgressRow.Status) {
        guard let id, let index = progress.firstIndex(where: { $0.id == id }) else { return }
        progress[index].status = status
    }

    // MARK: Ticker (elapsed, requests, the app-wide Keychain flag, the pause hold)

    private func startTicker(fresh: Bool = true) {
        if fresh { elapsedBefore = .zero; elapsedSeconds = 0 }
        runningSince = ContinuousClock.now
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func freezeElapsed() {
        if let runningSince { elapsedBefore += ContinuousClock.now - runningSince }
        runningSince = nil
    }

    private func stopTicker() {
        freezeElapsed()
        ticker?.cancel()
        ticker = nil
        watchKeychain()
    }

    /// Keeps `keychainBusy` true until a pending read (an earlier sheet's or run's) returns, also when no ticker runs.
    private func watchKeychain() {
        keychainBusy = environment.gate.isReading
        guard keychainBusy, keychainWatch == nil else { return }
        keychainWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                if !self.environment.gate.isReading { self.keychainBusy = false; break }
            }
            self?.keychainWatch = nil
        }
    }

    private func tick() async {
        let running = runningSince.map { ContinuousClock.now - $0 } ?? .zero
        elapsedSeconds = Int((elapsedBefore + running).components.seconds)
        keychainBusy = environment.gate.isReading
        guard let run else { return }
        requests = await run.requestCount()
        if case .awaitingMacOS = step, run.state == .running { step = .running }
        if step.isPaused { await run.expireHoldIfDue() }
        holdsSignIn = await run.holder.lifetime != .none
    }

    // MARK: Helpers

    private func makeItems(_ cache: GrokCache) -> [GrokFoundItem] {
        let built = GrokBundleBuilder.build(roster: cache.roster, transcripts: [:]).bundles
        return built.map { bundle in
            let newest = (cache.transcripts[bundle.sourceID] ?? []).compactMap { $0.objectValue?["seq"]?.intValue }.max() ?? 0
            var item = GrokFoundItem(
                id: bundle.sourceID, name: bundle.name, isGroup: bundle.isGroup, memberIDs: bundle.members.map(\.sourceID),
                mark: GrokAvatarMap.map(shape: bundle.avatarShape, colour: bundle.avatarColour, sourceID: bundle.sourceID),
                profile: bundle.profile, cachedMessages: cache.transcripts[bundle.sourceID]?.count ?? 0, newestCachedSeq: newest,
                hiddenInGrok: bundle.source.hiddenFromSidebar)
            let source = PreparedGrokBundle(GrokBotBundle(bundle))
            item.description = source.description
            item.needsDescriptionEdit = !bundle.isGroup && source.description.isEmpty
            item.memberNames = bundle.members.map(\.name)
            if let bot = store.bots.first(where: { $0.grokSourceID == bundle.sourceID }) {
                item.importedLines = bot.grokHistoryCount
                item.importedAt = store.grokHistory.lastModified(for: bot.id)
            } else if let group = store.groups.first(where: { $0.grokSourceID == bundle.sourceID }) {
                item.importedLines = group.grokHistoryCount
                item.importedAt = store.grokHistory.lastModified(for: group.id)
            }
            return item
        }
    }

    private func planNewBotIDs() {
        guard var plan = destinationPlan else { return }
        for item in items where !item.isGroup && plan.newBotIDs[item.id] == nil {
            plan.newBotIDs[item.id] = UUID()
        }
        destinationPlan = plan
    }

    func useExportBundles(_ bundles: [GrokBotBundle]) {
        guard driver == nil else { return }
        exportBundles = bundles
        fallback = nil
        run = nil
        availability = .recentExport
        mode = .recent
        items = bundles.map { bundle in
            let prepared = PreparedGrokBundle(bundle)
            return GrokFoundItem(id: bundle.sourceId, name: prepared.name, isGroup: bundle.isGroup ?? false,
                memberIDs: prepared.members.map(\.sourceID), mark: GrokAvatarMap.map(shape: bundle.avatar?.shape,
                    colour: bundle.avatar?.colour, sourceID: bundle.sourceId), profile: bundle.profile,
                cachedMessages: bundle.messages.count, newestCachedSeq: bundle.messages.map(\.seq).max() ?? 0,
                hiddenInGrok: bundle.source?.hiddenFromSidebar ?? false, description: prepared.description,
                needsDescriptionEdit: prepared.description.isEmpty,
                memberNames: prepared.members.map(\.name))
        }
        planNewBotIDs()
        selected = Set(items.map(\.id))
        step = .found
    }

    private func beginExport() {
        guard driver == nil, let exportBundles else { return }
        if !keepCommittedRows { committedRows = []; outcomes = [] }
        keepCommittedRows = false
        let bundles = exportBundles.filter { selected.contains($0.sourceId) }.sorted { $0.isGroup != true && $1.isGroup == true }
        let destination = destinationPlan
        let policy = GrokImportPolicy.inApp(refreshIdentity: refreshIdentity)
        progress = bundles.map { .init(id: $0.sourceId, name: $0.name, isGroup: $0.isGroup ?? false, newestSeq: 0) }
        step = .running
        startTicker()
        driver = Task {
            for bundle in bundles {
                if Task.isCancelled { break }
                let id = bundle.sourceId
                mark(id, .saving)
                var row = GrokImportRunRow(sourceID: id, name: bundle.name, isGroup: bundle.isGroup == true,
                    status: .done, coverage: .fileExport)
                do {
                    let imported = try await store.importGrokBundles([bundle], policy: policy, timing: nil, destination: destination)
                    row.archiveLines = imported.first?.historyCount ?? 0
                    row.created = imported.first?.created
                } catch {
                    row.status = .skipped
                    row.reason = (error as? LocalizedError)?.errorDescription ?? "The conversation could not be saved."
                }
                handle(.committed(row))
            }
            await settle(Task.isCancelled ? .cancelled : .finished)
        }
    }

    private func secretsOlderThanADay() -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: environment.location.secretsFile.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }
        return environment.now().timeIntervalSince(modified) > 24 * 3600
    }
}

extension GrokImportCoordinator.Step {
    var isPaused: Bool { if case .paused = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

extension GrokProgressRow.Status {
    var isActive: Bool { self == .fetching || self == .readingCache || self == .saving }
}
