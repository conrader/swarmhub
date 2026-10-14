import AppKit
import Foundation

/// The import sheet's state (briefs/P10.md P10d 2): one `GrokImportRun` per sheet session, the same pipeline as
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
    @Published var progress: [GrokProgressRow] = []
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
    private var startedAt = ContinuousClock.now

    init(store: AppStore, environment: GrokImportEnvironment,
         isGrokRunning: @escaping @Sendable () -> Bool = { GrokImportCoordinator.grokBotIsRunning() }) {
        self.store = store
        self.environment = environment
        self.isGrokRunning = isGrokRunning
    }

    nonisolated static func grokBotIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: GrokProtocol.bundleIdentifier).isEmpty
    }

    var serverURL: String? { store.grokSettingsServerURL }
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
        step = .scanning
        let found = await GrokPreflight.run(location: environment.location, passwords: environment.passwords)
        preflight = found
        grokVersion = found.versionReadable ? found.clientVersion : nil
        availability = GrokLocator.availability(found, persistenceEnabled: store.persistenceEnabled)
        items = found.cache.map(makeItems) ?? []
        selected = Set(items.map(\.id))
        mode = availability == .ready ? .full : .recent
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
        guard !selected.isEmpty, availability?.canImport == true else { return }
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
        return GrokImportOptions(mode: mode, selection: ids.count == items.count ? nil : ids, refreshIdentity: refreshIdentity)
    }

    /// `fresh`: a new run (Start, Try again, Recent only) rather than a continuation of the paused or cancelled one.
    private func begin(fresh: Bool, _ action: @escaping @MainActor (GrokImportRun, GrokImportOptions) async -> GrokImportRunState) {
        guard driver == nil else { return }
        let run = currentRun(), options = options()
        if fresh {
            resetProgress(options)
            if !keepCommittedRows { committedRows = []; outcomes = [] }
            keepCommittedRows = false
        }
        step = .running
        startTicker()
        driver = Task { [weak self] in
            let state = await action(run, options)
            await self?.settle(state)
        }
    }

    private func resetProgress(_ options: GrokImportOptions) {
        guard let cache = preflight?.cache else { progress = []; return }
        let order = (try? GrokImportRun.conversations(in: cache, selection: options.selection)) ?? []
        progress = order.compactMap { id in
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
            step = .finished
            stopTicker()
        case .paused(let pause):
            mark(current, .paused)
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
            mark(id, mode == .full ? .fetching : .readingCache)
        case .page(let pages, let oldest):
            guard let current, let index = progress.firstIndex(where: { $0.id == current }),
                  progress[index].status == .fetching else { return }
            progress[index].pages = pages
            progress[index].oldestSeq = oldest
        case .saving(let id):
            mark(id, .saving)
        case .committed(let row):
            if let index = committedRows.firstIndex(where: { $0.sourceID == row.sourceID }) { committedRows[index] = row }
            else { committedRows.append(row) }
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

    private func startTicker() {
        startedAt = ContinuousClock.now
        elapsedSeconds = 0
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopTicker() {
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
        elapsedSeconds = Int((ContinuousClock.now - startedAt).components.seconds)
        keychainBusy = environment.gate.isReading
        guard let run else { return }
        requests = await run.requestCount()
        if case .awaitingMacOS = step, run.state == .running { step = .running }
        if step.isPaused { await run.expireHoldIfDue() }
        holdsSignIn = await run.holder.lifetime != .none
    }

    // MARK: Helpers

    private func makeItems(_ cache: GrokCache) -> [GrokFoundItem] {
        let built = GrokBundleBuilder.build(cache).bundles
        return built.map { bundle in
            let newest = (cache.transcripts[bundle.sourceID] ?? []).compactMap { $0.objectValue?["seq"]?.intValue }.max() ?? 0
            var item = GrokFoundItem(
                id: bundle.sourceID, name: bundle.name, isGroup: bundle.isGroup, memberIDs: bundle.members.map(\.sourceID),
                mark: GrokAvatarMap.map(shape: bundle.avatarShape, colour: bundle.avatarColour, sourceID: bundle.sourceID),
                profile: bundle.profile, cachedMessages: bundle.messages.count, newestCachedSeq: newest,
                hiddenInGrok: bundle.source.hiddenFromSidebar)
            if let bot = store.bots.first(where: { $0.grokSourceID == bundle.sourceID }) {
                item.profile = bot.hermesProfile
                item.importedLines = bot.grokHistoryCount
                item.importedAt = store.grokHistory.lastModified(for: bot.id)
            } else if let group = store.groups.first(where: { $0.grokSourceID == bundle.sourceID }) {
                item.importedLines = group.grokHistoryCount
                item.importedAt = store.grokHistory.lastModified(for: group.id)
            }
            return item
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
