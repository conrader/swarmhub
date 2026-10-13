import AppKit
import Foundation

/// What the real views report as they appear; read only by `--ui-smoke`.
@MainActor enum UISmokeProbe {
    static var renderedChats: Set<UUID> = []
    /// Archive id → message count shown in its "Grok history" header.
    static var historyHeaders: [UUID: Int] = [:]
    /// P15: "<place>|<bot id>" → what that rendered avatar shows (`AvatarFacts`), and how many live kit views exist.
    static var avatarFacts: [String: [String: Any]] = [:]
    static var liveAvatarViews = 0
    /// P15: a bot `AppStore.isWorking` reports as working, for the smoke's display-link probe only.
    static var forcedWorking: UUID?
}

/// `SwarmHub --ui-smoke <report.json>`: the normal app with its window on screen. Once the first Grok bot's chat has
/// rendered, the app writes a JSON report about its own state (no screenshots, no automation) and keeps running.
@MainActor enum UISmoke {
    struct Budget {
        var window: Duration = .seconds(30)
        var chat: Duration = .seconds(20)
        var overview: Duration = .seconds(20)
        var routines: Duration = .seconds(15)
        var avatars = AvatarSmoke.Budget()
        var layout: Duration = .seconds(5)
    }

    static func reportPath(arguments: [String] = CommandLine.arguments) -> String? {
        guard let flag = arguments.firstIndex(of: "--ui-smoke"), arguments.indices.contains(flag + 1) else { return nil }
        return (arguments[flag + 1] as NSString).expandingTildeInPath
    }

    static func start(store: AppStore, path: String) {
        Task { @MainActor in
            let report = await collect(store: store)
            do { try write(report, to: URL(fileURLWithPath: path)) }
            catch { NSLog("%@ ui-smoke: cannot write %@: %@", AppConstants.name, path, error.localizedDescription) }
        }
    }

    static func collect(store: AppStore, budget: Budget = .init(), window: @escaping @MainActor () -> NSWindow? = { mainWindow() }) async -> [String: Any] {
        var errors: [String] = []
        var report: [String: Any] = ["launch_selection": launchSelection(store, errors: &errors)]
        let bot = store.bots.first { $0.grokSourceID != nil && !$0.isReadOnlyArchive && !$0.isHidden } ?? store.bots.first { !$0.isHidden }
        if let bot { store.open(bot, remember: false); store.showInfo = true } else { errors.append("no bot to select") }

        let windowShown = await HeadlessE2E.wait(budget.window, poll: .milliseconds(100)) { window()?.isVisible == true }
        if !windowShown { errors.append("main window not visible within \(budget.window)") }
        report["window_visible"] = window()?.isVisible == true; report["window_unoccluded"] = window()?.occlusionState.contains(.visible) == true
        if let frame = window()?.frame { report["window_frame"] = ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height] }
        report["window_on_screen"] = window()?.screen != nil
        let info = Bundle.main.infoDictionary ?? [:]
        report["app"] = ["name": AppConstants.name, "window_title": window()?.title ?? NSNull(), "bundle_name": info["CFBundleName"] ?? NSNull(),
                         "bundle_display_name": info["CFBundleDisplayName"] ?? NSNull(), "bundle_id": Bundle.main.bundleIdentifier ?? NSNull()]
        if let title = window()?.title, title != AppConstants.name { errors.append("window title is \(title), not \(AppConstants.name)") }

        report["sidebar_rows"] = ["bots": store.bots.filter { !$0.isHidden }.count, "groups": store.groups.filter { !$0.isHidden }.count,
                                  "total": store.bots.filter { !$0.isHidden }.count + store.groups.filter { !$0.isHidden }.count]
        if let bot {
            let rendered = await HeadlessE2E.wait(budget.chat, poll: .milliseconds(100)) { UISmokeProbe.renderedChats.contains(bot.id) }
            if !rendered { errors.append("\(bot.name)'s chat did not render within \(budget.chat)") }
            report["selected_bot"] = ["name": bot.name, "profile": bot.hermesProfile ?? "default", "chat_rendered": rendered, "is_selected": store.selectedBot?.id == bot.id]

            let archived = store.grokHistory.messages(for: bot.id).count
            let shown = UISmokeProbe.historyHeaders[bot.id]
            report["grok_history"] = ["header_shown": shown != nil, "header_count": shown.map { $0 as Any } ?? NSNull(), "expected_count": bot.grokHistoryCount,
                                      "archive_messages": archived, "matches": shown == bot.grokHistoryCount && archived == bot.grokHistoryCount]

            _ = await HeadlessE2E.wait(budget.overview, poll: .milliseconds(200)) {
                guard let info = store.botInfo.info(for: bot.id) else { return false }
                return info.skills != .loading && !info.isRefreshing
            }
            report["overview"] = overview(store.botInfo.info(for: bot.id), errors: &errors)

            Task { await store.refreshRoutines(for: bot) }
            _ = await HeadlessE2E.wait(budget.routines, poll: .milliseconds(200)) { store.routines.state(for: bot.id).jobs != .loading }
            report["routines"] = routines(store.routines.state(for: bot.id), errors: &errors)
        }
        report["avatars"] = await AvatarSmoke.collect(store: store, bot: bot, budget: budget.avatars)
        let chrome = await UISmokeChrome.collect(window: window(), store: store, budget: budget.layout)
        report["chrome"] = chrome
        errors += (chrome["errors"] as? [String] ?? []) + ((chrome["fullscreen"] as? [String: Any])?["errors"] as? [String] ?? [])
        if let message = store.errorMessage { errors.append("alert: \(message)") }
        report["errors"] = errors
        report["source"] = Bundle.main.url(forResource: "SOURCE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .split(separator: "\n").first.map(String.init) ?? "unknown"
        report["written_at"] = ISO8601DateFormatter().string(from: .now)
        return report
    }

    /// The chat the app opened at launch, before the smoke opens its own: never a hidden or demo bot (P18 item 9).
    static func launchSelection(_ store: AppStore, errors: inout [String]) -> [String: Any] {
        if let group = store.selectedGroup {
            if group.isHidden { errors.append("launch selected hidden group \(group.name)") }
            return ["kind": "group", "name": group.name, "hidden": group.isHidden, "demo": false]
        }
        guard let bot = store.selectedBot else { return ["kind": "none"] }
        if bot.isHidden || bot.isDemo { errors.append("launch selected \(bot.isDemo ? "demo" : "hidden") bot \(bot.name)") }
        return ["kind": "bot", "name": bot.name, "hidden": bot.isHidden, "demo": bot.isDemo]
    }

    static func overview(_ info: BotServerInfo?, errors: inout [String]) -> [String: Any] {
        guard let info else { errors.append("overview: no server info"); return ["state": "not loaded"] }
        switch info.skills {
        case .loaded(let skills): return ["state": "loaded", "skills": skills.count, "toolsets": info.toolsets.value.map { $0.count as Any } ?? NSNull()]
        case .loading: errors.append("overview: skills still loading"); return ["state": "loading"]
        case .unavailable(let reason), .failed(let reason): errors.append("overview: \(reason)"); return ["state": "unavailable", "reason": reason]
        }
    }

    static func routines(_ state: BotRoutinesState, errors: inout [String]) -> [String: Any] {
        switch state.jobs {
        case .loaded(let jobs): return ["state": "loaded", "jobs": jobs.count, "paused": jobs.filter(\.isPaused).count]
        case .loading: errors.append("routines: still loading"); return ["state": "loading"]
        case .unavailable(let reason), .failed(let reason): errors.append("routines: \(reason)"); return ["state": "unavailable", "reason": reason]
        }
    }

    static func mainWindow() -> NSWindow? {
        NSApp?.windows.first { $0.isVisible && $0.title == AppConstants.name } ?? NSApp?.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    /// Written atomically with mode 0600 in a 0700 directory.
    static func write(_ report: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
