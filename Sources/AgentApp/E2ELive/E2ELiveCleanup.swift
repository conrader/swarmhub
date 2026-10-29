import AppKit
import Foundation

/// uxfix3: the run leaves nothing behind on the box and nothing on the screen.
/// Sessions: every session this run opens carries its own prefix `runNamespace` (`swarmhub-selftest-r<tag>-…`). Before
/// and after the run, self-test sessions (`AppConstants.selfTestPrefixes`) on each profile the copies use are deleted
/// through the box's normal API (`GET /api/sessions`, `DELETE /api/sessions/{id}`): this run's own always, any other
/// (another job's run, or one left over) only when it has been quiet for 20 minutes. No other session is touched.
/// A profile whose sessions cannot be listed, before or after the deletes, fails the check.
/// Screen: the app runs hidden with no Dock icon; its windows stay transparent and click-through even if it is unhidden.
extension E2ELive {
    nonisolated static let runNamespace = "\(AppConstants.selfTestPrefix)r\(tag)-"
    nonisolated static let otherRunQuiet: TimeInterval = 20 * 60

    static func cleanSelfTestSessions(store: AppStore, run: Run, phase: String) async {
        var backends: [String: HermesBackend] = [:]
        for bot in store.bots {
            guard let backend = try? store.backend(for: bot) as? HermesBackend else { continue }
            let scope = "\(backend.baseURL.absoluteString)|\(backend.profile)"
            if backends[scope] == nil { backends[scope] = backend }
        }
        await cleanSelfTestSessions(Array(backends.values), run: run, phase: phase)
    }

    /// One pass over distinct profiles: delete, then read back.
    static func cleanSelfTestSessions(_ backends: [HermesBackend], run: Run, phase: String) async {
        var deleted = 0, kept = 0; var failed: [String] = []
        for backend in backends {
            let rows: [[String: Any]]
            do { rows = try await selfTestRows(backend) } catch { failed.append("\(backend.profile): GET /api/sessions \(error.localizedDescription)"); continue }
            for row in rows {
                guard let id = row["id"] as? String else { continue }
                guard isDeletable(row, now: Date()) else { kept += 1; continue }
                do { _ = try await backend.jsonRequest(path: "api/sessions/\(HermesBackend.escapedPath(id))", method: "DELETE"); deleted += 1 }
                catch { failed.append("\(backend.profile)/\(id): \(error.localizedDescription)") }
            }
        }
        // Read back on every profile: what is left must be only the sessions another run may still be using. A profile
        // that cannot be read back is a failure, never an empty list.
        var left = 0
        for backend in backends {
            do { left += try await selfTestRows(backend).filter { isDeletable($0, now: Date()) }.count }
            catch { failed.append("\(backend.profile): read-back GET /api/sessions \(error.localizedDescription)") }
        }
        run.check("cleanup.\(phase)", !backends.isEmpty && failed.isEmpty && left == 0,
                  "\(deleted) self-test sessions deleted on \(backends.count) profile(s), \(kept) kept (another run's, active in the last 20 min), \(left) left" + (failed.isEmpty ? "" : "; " + failed.prefix(6).joined(separator: "; ")))
    }

    /// This run's own sessions (id under `runNamespace`) always; any other only when it has been quiet for `otherRunQuiet`.
    /// When it started does not make a session this run's: another run may have started after this one.
    nonisolated static func isDeletable(_ row: [String: Any], now: Date, owner: String = runNamespace) -> Bool {
        guard let id = row["id"] as? String, AppConstants.isSelfTestSession(id) else { return false }
        if id.hasPrefix(owner) { return true }
        func time(_ key: String) -> Double? { (row[key] as? NSNumber)?.doubleValue }
        guard let last = time("last_active") ?? time("started_at") else { return false }
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
