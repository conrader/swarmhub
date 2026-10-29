import AppKit
import Foundation

/// uxfix3: the run leaves nothing behind on the box and nothing on the screen.
/// Sessions: before and after the run, every `swarmhub-selftest-…` session (`AppConstants.selfTestPrefixes`) on each
/// profile the copies use is deleted through the box's normal API (`GET /api/sessions`, `DELETE /api/sessions/{id}`).
/// No other session is touched; a left-over one active in the last 20 minutes (another job's run) is left alone.
/// Screen: the app runs hidden with no Dock icon; its windows stay transparent and click-through even if it is unhidden.
extension E2ELive {
    nonisolated static let runStart = Date()
    nonisolated static let otherRunQuiet: TimeInterval = 20 * 60

    static func cleanSelfTestSessions(store: AppStore, run: Run, phase: String) async {
        var scopes: Set<String> = []; var deleted = 0, kept = 0; var failed: [String] = []
        for bot in store.bots {
            guard let backend = try? store.backend(for: bot) as? HermesBackend,
                  scopes.insert("\(backend.baseURL.absoluteString)|\(backend.profile)").inserted else { continue }
            let rows: [[String: Any]]
            do { rows = try await selfTestRows(backend) } catch { failed.append("\(backend.profile): GET /api/sessions \(error.localizedDescription)"); continue }
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                guard isDeletable(row, now: Date()) else { kept += 1; continue }
                do { _ = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(id))", method: "DELETE"); deleted += 1 }
                catch { failed.append("\(backend.profile)/\(id): \(error.localizedDescription)") }
            }
        }
        // Read back: what is left must be only the sessions another run may still be using.
        var left = 0
        for bot in store.bots {
            guard let backend = try? store.backend(for: bot) as? HermesBackend else { continue }
            left += ((try? await selfTestRows(backend)) ?? []).filter { isDeletable($0, now: Date()) }.count
            if left > 0 { break }
        }
        run.check("cleanup.\(phase)", failed.isEmpty && left == 0,
                  "\(deleted) self-test sessions deleted on \(scopes.count) profile(s), \(kept) kept (active in another run), \(left) left" + (failed.isEmpty ? "" : "; " + failed.prefix(6).joined(separator: "; ")))
    }

    /// The run's own sessions always; an older one only when it has been quiet for `otherRunQuiet`.
    nonisolated static func isDeletable(_ row: [String: Any], now: Date) -> Bool {
        func time(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        if let started = time("started_at"), started >= runStart.timeIntervalSince1970 - 5 { return true }
        let last = time("last_active") ?? time("started_at") ?? 0
        return now.timeIntervalSince1970 - last > otherRunQuiet
    }

    /// Every self-test session of the profile, paged (read only).
    static func selfTestRows(_ backend: HermesBackend) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []; var offset = 0; let limit = 200
        for _ in 0..<50 {
            let json = try await backend.jsonRequest(path: "api/sessions?limit=\(limit)&offset=\(offset)")
            let page = (json["data"] as? [[String: Any]]) ?? (json["sessions"] as? [[String: Any]]) ?? []
            rows += page.filter { row in (row["id"] as? String).map { id in AppConstants.selfTestPrefixes.contains { id.hasPrefix($0) } } ?? false }
            if page.count < limit { break }
            offset += page.count
        }
        return rows
    }

    // MARK: The Mac's own network

    /// uxfix3 (round 1: the MacBook itself went offline for the rest of the run): before a step that reads or writes the
    /// box, wait up to `limit` for one read-only `GET /v1/skills` to answer. Notes how long the box was unreachable.
    @discardableResult static func waitForBox(store: AppStore, bot: Bot, run: Run, before step: String, limit: Duration = .seconds(20 * 60)) async -> Bool {
        guard let backend = try? store.backend(for: bot) as? HermesBackend else { return false }
        let clock = ContinuousClock(), start = clock.now
        var lastError = ""
        while clock.now - start < limit {
            do {
                _ = try await backend.skills()
                if !lastError.isEmpty { run.note("E2E-LIVE: the box answered again before \(step) after \(clock.now - start) (\(lastError))") }
                return true
            } catch { lastError = error.localizedDescription }
            try? await Task.sleep(for: .seconds(15))
        }
        run.note("E2E-LIVE: the box did not answer for \(limit) before \(step): \(lastError)")
        return false
    }

    // MARK: Off screen

    /// No Dock icon, hidden, and every window transparent and click-through.
    static func keepOffScreen() {
        if NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
        for window in NSApp.windows where window.alphaValue > 0 || !window.ignoresMouseEvents {
            window.alphaValue = 0; window.ignoresMouseEvents = true
        }
        if !NSApp.isHidden { NSApp.hide(nil) }
    }

    /// Windows a person could see right now (0 for the whole run is the pass).
    static var windowsOnScreen: Int {
        NSApp.isHidden ? 0 : NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0 }.count
    }
}
