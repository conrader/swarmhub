import Darwin
import Foundation

/// `AgentApp --check-reports [<base URL>]` (P36): SwarmHub reports end to end, as Send does it, against the production
/// base or the given one. An in-memory key store and a throwaway reports file (no Keychain, no real store.json):
/// registers an install, posts one self-test report, lists the reports. Prints
/// `REPORTS: install ok | sent <id> | listed <yes/no> | status <status>`; the install key is never printed.
/// Exit 0 only when every step succeeded, otherwise the failing step is printed and the exit code is 1.
@MainActor enum HeadlessCheckReports {
    static let flag = "--check-reports"
    static let usage = "Usage: AgentApp --check-reports [<base URL>]"
    static let title = "Self-test from the release check (ignore)"
    static let body = "Automated end-to-end check of SwarmHub reports."

    static func run(arguments: [String]) -> Int32 {
        guard let flagIndex = arguments.firstIndex(of: flag) else { print(usage); return 64 }
        var raw = SwarmHubService.defaultBaseURL
        if arguments.indices.contains(flagIndex + 1), !arguments[flagIndex + 1].hasPrefix("--") { raw = arguments[flagIndex + 1] }
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { print(usage); return 64 }
        let service = SwarmHubService(baseURL: url, session: URLSession(configuration: TestRunGuard.guarded(.ephemeral)))
        return HeadlessRunLoop.wait { await check(service: service, output: { print($0); fflush(stdout) }) }
    }

    /// The whole check against `service`; tests pass a stubbed session.
    static func check(service: SwarmHubService, appVersion: String = AppBuildInfo.current().version, output: (String) -> Void) async -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AgentApp-check-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let center = ReportsCenter(fileURL: directory.appending(path: "reports.json"), keyStore: MemoryKeyStore())
        center.session = service.session
        func failed(_ step: String, _ error: Error) -> Int32 {
            output("REPORTS: \(step) failed | \((error as? SwarmHubError)?.message ?? error.localizedDescription)"); return 1
        }

        do { _ = try await center.install(service: service) } catch { return failed("install", error) }
        let report = SwarmReport(id: "u-\(UUID().uuidString.lowercased())", source: .user, kind: .bug, title: title, body: body, createdAt: Date())
        guard let payload = ReportPayload(report, appVersion: appVersion) else { output("REPORTS: send failed | the self-test report is empty"); return 1 }
        let sent: (id: String, status: String)
        do { sent = try await center.withReportsAuth(service: service) { try await service.postReport(payload, auth: $0) } }
        catch { return failed("send", error) }
        let rows: [ServerReport]
        do { rows = try await center.withReportsAuth(service: service) { try await service.listReports(auth: $0) } }
        catch { return failed("list", error) }
        let listed = rows.first { $0.id == sent.id }
        output("REPORTS: install ok | sent \(sent.id) | listed \(listed == nil ? "no" : "yes") | status \(listed?.status ?? sent.status)")
        guard listed != nil else { output("REPORTS: list failed | \(sent.id) is not in the list"); return 1 }
        return 0
    }
}
