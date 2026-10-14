import Foundation

/// The Grok Bot commands (briefs/P10.md P10c 3). Unlike the other headless commands they never call
/// `SecKeychainSetUserInteractionAllowed(false)` (it is process-wide, and `--grok-fetch --mode full` / `--grok-probe --live`
/// need the one macOS dialog). Output is counts, booleans and states only: no names, ids, text or anything secret.
///   AgentApp --grok-fetch --mode recent|full [--bots "<name>,<name>"] [--store <store.json>] [--report <file>]
///   AgentApp --grok-probe [--live] [--report <file>]
///   AgentApp --grok-parity <python export folder> [--cache <folder>]   (see HeadlessGrokParity.swift)
@MainActor enum HeadlessGrok {
    nonisolated static let keychainNotice =
        "KEYCHAIN PROMPT COMING: macOS asks for \"Grok Bot Safe Storage\". Click Allow (not Always Allow)."

    static func runIfRequested(arguments: [String]) -> Int32? {
        if arguments.contains("--grok-parity") { return GrokParity.run(arguments: arguments, output: { print($0) }) }
        if arguments.contains("--grok-probe") { return HeadlessRunLoop.wait { await probe(arguments: arguments, output: emit) } }
        if arguments.contains("--grok-fetch") { return HeadlessRunLoop.wait { await fetch(arguments: arguments, output: emit) } }
        return nil
    }

    nonisolated private static func emit(_ line: String) {
        print(line)
        fflush(stdout)
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    // MARK: --grok-probe

    static func probe(arguments: [String], environment: GrokImportEnvironment? = nil,
                      output: @escaping @Sendable (String) -> Void) async -> Int32 {
        let live = arguments.contains("--live")
        let notice = keychainNotice
        let report = await GrokProbe.run(environment: environment ?? .live(appVersion: appVersion), live: live) { output(notice) }
        for line in lines(for: report) { output(line) }
        if let path = value(after: "--report", in: arguments) { write(probeJSON(report), to: path) }
        return report.ok ? 0 : 1
    }

    static func lines(for report: GrokProbeReport) -> [String] {
        var lines = [
            "grokBotFound=\(report.grokBotFound) dataFolderFound=\(report.dataFolderFound) version=\(report.grokBotVersion) " +
                "versionReadable=\(report.versionReadable)",
            "cacheReadable=\(report.cacheReadable) rosterRows=\(report.rosterRows) bots=\(report.bots) groups=\(report.groups) " +
                "cachedTranscripts=\(report.cachedTranscripts)",
            "secretsShapeOK=\(report.secretsShapeOK) accounts=\(report.accounts) machineIDStored=\(report.machineIDStored) " +
                "accountBinding=\(report.accountBinding)",
            "keychainItemPresent=\(report.keychainItemPresent) keychainProbeMs=\(report.keychainProbeMs) serverReady=\(report.serverReady)",
        ]
        if let problem = report.cacheProblem { lines.insert("cacheProblem=\(problem)", at: 2) }
        if let live = report.live {
            lines.append("live keychainReadOK=\(live.keychainReadOK) tokenShapeOK=\(live.tokenShapeOK) tokenValid=\(live.tokenValid) " +
                         "machineIDPresent=\(live.machineIDPresent) teamIDPresent=\(live.teamIDPresent) " +
                         "canaryOK=\(live.canaryOK) canaryRows=\(live.canaryRows)" +
                         (live.failure.map { " failure=\($0)" } ?? ""))
        }
        lines.append("probe \(report.ok ? "OK" : "NOT OK")")
        return lines
    }

    // MARK: --grok-fetch

    static func fetch(arguments: [String], store: AppStore? = nil, environment: GrokImportEnvironment? = nil,
                      output: @escaping (String) -> Void) async -> Int32 {
        guard let raw = value(after: "--mode", in: arguments), let mode = GrokImportMode(rawValue: raw) else {
            output("Usage: AgentApp --grok-fetch --mode recent|full [--bots \"<name>,<name>\"] [--store <store.json>] [--report <file>]")
            return 64
        }
        let selection = value(after: "--bots", in: arguments).map { $0.split(separator: ",").map(String.init) }
        let storeURL = value(after: "--store", in: arguments).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let store = store ?? AppStore(storeURL: storeURL, autoConfigureHermes: false)
        if mode == .full {
            output("Mode full: \(AppConstants.name) reads Grok Bot's sign-in once; macOS will show its own Keychain window. " +
                   "Click Allow, not Always Allow.")
        }
        let run = GrokImportRun(store: store, environment: environment ?? .live(appVersion: appVersion),
                                options: GrokImportOptions(mode: mode, selection: selection))
        run.onEvent = { event in
            switch event {
            case .keychainReadComing: output(keychainNotice)
            case .committed(let row): output("conversation \(run.rows.count): " + describe(row))
            case .conversation, .page, .saving: break
            }
        }
        let state = await run.start()
        let requests = await run.requestCount()
        let rows = run.rows
        let done = rows.filter { $0.status == .done }.count
        let incomplete = rows.filter { $0.status == .incomplete }.count
        output("state=\(describe(state)) conversations=\(rows.count) done=\(done) incomplete=\(incomplete) " +
               "skipped=\(rows.filter { $0.status == .skipped }.count) messages=\(rows.map(\.messages).reduce(0, +)) " +
               "added=\(rows.map(\.addedLines).reduce(0, +)) requests=\(requests) keychainReads=\(run.keychainReads)")
        if case .stopped(let error) = state { output("stopped: \(error.errorDescription ?? "unknown")") }
        if case .paused(let pause) = state {
            output("paused: \(describe(pause)); run the command again to continue (nothing is duplicated).")
        }
        if let path = value(after: "--report", in: arguments) {
            write(fetchJSON(state: state, rows: rows, requests: requests, keychainReads: run.keychainReads), to: path)
        }
        let complete = state == .finished && !rows.isEmpty && rows.allSatisfy { $0.status == .done }
        return complete ? 0 : 1
    }

    static func describe(_ row: GrokImportRunRow) -> String {
        "\(row.isGroup ? "group" : "bot") \(row.status.rawValue) coverage=\(row.coverage.rawValue) cached=\(row.cachedEntries) " +
            "fetched=\(row.fetchedEntries) messages=\(row.messages) archive=\(row.archiveLines) added=\(row.addedLines) " +
            "pages=\(row.stats.pages) blobsRead=\(row.stats.blobsRead) blobsMissing=\(row.stats.blobsMissing) " +
            "omittedRefetched=\(row.stats.omittedRefetched) unreadable=\(row.stats.unreadable) gapRanges=\(row.gapRanges) " +
            "missingSeqs=\(row.missingSeqs)"
    }

    static func describe(_ state: GrokImportRunState) -> String {
        switch state {
        case .idle: "idle"
        case .preflighting: "preflighting"
        case .awaitingMacOS: "awaitingMacOS"
        case .running: "running"
        case .paused: "paused"
        case .finished: "finished"
        case .stopped: "stopped"
        case .cancelled: "cancelled"
        }
    }

    static func describe(_ pause: GrokImportPause) -> String {
        switch pause {
        case .network(let error): "network (\(error.description))"
        case .tokenExpired: "the Grok Bot sign-in has expired; open Grok Bot once"
        case .signInInvalid: "Grok no longer accepts this sign-in; macOS will ask again"
        }
    }

    // MARK: Reports (0600; counts, booleans and states only)

    private static func probeJSON(_ report: GrokProbeReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(report)
    }

    private static func fetchJSON(state: GrokImportRunState, rows: [GrokImportRunRow], requests: Int, keychainReads: Int) -> Data? {
        let rowObjects: [[String: Any]] = rows.map { row in
            ["isGroup": row.isGroup, "status": row.status.rawValue, "coverage": row.coverage.rawValue, "cached": row.cachedEntries,
             "fetched": row.fetchedEntries, "messages": row.messages, "archive": row.archiveLines, "added": row.addedLines,
             "pages": row.stats.pages, "rows": row.stats.rows, "blobsRead": row.stats.blobsRead, "blobsMissing": row.stats.blobsMissing,
             "omittedRefetched": row.stats.omittedRefetched, "unreadable": row.stats.unreadable, "gapRanges": row.gapRanges,
             "missingSeqs": row.missingSeqs]
        }
        let object: [String: Any] = ["state": describe(state), "requests": requests, "keychainReads": keychainReads,
                                     "conversations": rowObjects]
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func write(_ data: Data?, to path: String) {
        guard let data else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }
}
