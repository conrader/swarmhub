import Foundation
import Testing
@testable import AgentApp

private actor ReadGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}
private func statusRead(_ code: Int = 200, retryAfter: String? = nil) -> HermesStatusScheduler.Read {
    .init(data: Data("{}".utf8), response: HTTPURLResponse(url: URL(string: "https://status.test/health")!, statusCode: code,
        httpVersion: "HTTP/1.1", headerFields: retryAfter.map { ["Retry-After": $0] })!)
}
private func statusRequest(_ path: String = "health", host: String = "status.test") -> URLRequest {
    URLRequest(url: URL(string: "https://\(host)/\(path)")!)
}

@Test @MainActor func statusBurstsCoalesceWithoutCachingLaterReconciliationReads() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0.01, jitter: { 0 }))
    let gate = ReadGate(), calls = AwaitableLog<Bool>()
    let readers = (0..<20).map { _ in Task {
        try await scheduler.read(statusRequest(), scope: "same-profile-key") {
            calls.append(true); await gate.wait(); return statusRead()
        }
    } }
    try await waitUntil { await scheduler.pendingReadCount == 20 }
    await gate.release()
    for reader in readers { _ = try await reader.value }
    #expect(calls.all.count == 1)
    // Later reads must observe new run/history state, rather than a cached successful GET.
    _ = try await scheduler.read(statusRequest(), scope: "same-profile-key") { calls.append(true); return statusRead() }
    #expect(calls.all.count == 2)
}

@Test func statusRequestsAcrossProfilesAndKeysShareHostSpacingAndDebounce() async throws {
    let timing = HermesStatusScheduler.Timing(tick: .milliseconds(1), spacing: 0.03, debounce: 0.02, jitter: { 0.005 })
    let scheduler = HermesStatusScheduler(timing: timing), calls = AwaitableLog<Date>()
    let began = Date()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for n in 0..<6 {
            group.addTask {
                _ = try await scheduler.read(statusRequest("p/\(n)/health"), scope: "profile-key-\(n)") { calls.append(Date()); return statusRead() }
            }
        }
        try await group.waitForAll()
    }
    let starts = calls.all.sorted()
    #expect(starts.count == 6 && starts[0].timeIntervalSince(began) >= 0.02)
    for pair in zip(starts, starts.dropFirst()) { #expect(pair.1.timeIntervalSince(pair.0) >= 0.03) }
}

@Test @MainActor func statusConcurrencyIsCappedPerHostWhileOtherHostsProceed() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, jitter: { 0 }))
    let gate = ReadGate(), calls = AwaitableLog<String>()
    let readers = (0..<5).map { n in Task {
        let host = n == 4 ? "other.test" : "status.test"
        return try await scheduler.read(statusRequest("health/\(n)", host: host), scope: "scope-\(n)") {
            calls.append(host); await gate.wait(); return statusRead()
        }
    } }
    try await calls.wait { $0.count >= 3 }
    #expect(calls.all.filter { $0 == "status.test" }.count == 2)
    #expect(calls.all.filter { $0 == "other.test" }.count == 1)
    await gate.release()
    for reader in readers { _ = try await reader.value }
    #expect(calls.all.count == 5)
}

@Test(arguments: [429, 503]) func busyStatusResponsesBackOffAndRecoverWithoutSurfacingHTTPFailure(code: Int) async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0.02, jitter: { 0 }))
    let calls = AwaitableLog<Date>()
    let read = try await scheduler.read(statusRequest(), scope: "key") {
        calls.append(Date())
        return statusRead(calls.all.count < 3 ? code : 200)
    }
    #expect((read.response as? HTTPURLResponse)?.statusCode == 200)
    let starts = calls.all
    #expect(starts.count == 3)
    #expect(starts[1].timeIntervalSince(starts[0]) >= 0.02)
    #expect(starts[2].timeIntervalSince(starts[1]) >= 0.04)
}

@Test @MainActor func retryAfterPausesAllProfilesOnTheSameHost() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0, jitter: { 0 }))
    let calls = AwaitableLog<Date>(), replied = AwaitableLog<Bool>()
    let first = Task {
        try await scheduler.read(statusRequest("p/a/health"), scope: "key-a") {
            calls.append(Date())
            if calls.all.count == 1 { replied.append(true); return statusRead(503, retryAfter: "0.1") }
            return statusRead()
        }
    }
    try await replied.wait { !$0.isEmpty }
    // Wait for the first response's backoff to be installed by actor admission before adding another profile.
    try await Task.sleep(for: .milliseconds(10))
    _ = try await scheduler.read(statusRequest("p/b/health"), scope: "key-b") { calls.append(Date()); return statusRead() }
    _ = try await first.value
    #expect(calls.all.count == 3)
    #expect(calls.all.dropFirst().allSatisfy { $0.timeIntervalSince(calls.all[0]) >= 0.1 })
}

@Test func persistentBusyStatusDefersAfterFourAttemptsAndDoesNotExpose429() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0, jitter: { 0 }))
    let calls = AwaitableLog<Bool>()
    do {
        _ = try await scheduler.read(statusRequest(), scope: "key") { calls.append(true); return statusRead(429) }
        Issue.record("Expected deferred status")
    } catch is HermesStatusDeferred {}
    #expect(calls.all.count == 4)
}

@Test @MainActor func cancellingOneCoalescedReaderPreservesTheOtherAndTheFetch() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, jitter: { 0 }))
    let gate = ReadGate(), calls = AwaitableLog<Bool>()
    let fetch: @Sendable () async throws -> HermesStatusScheduler.Read = { calls.append(true); await gate.wait(); return statusRead() }
    let first = Task { try await scheduler.read(statusRequest(), scope: "key", fetch: fetch) }
    let second = Task { try await scheduler.read(statusRequest(), scope: "key", fetch: fetch) }
    try await waitUntil { await scheduler.pendingReadCount == 2 }
    first.cancel()
    do { _ = try await first.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    await gate.release()
    _ = try await second.value
    #expect(calls.all.count == 1)
}

@Test @MainActor func cancelledQueuedStatusNeverReachesTheServer() async throws {
    let scheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 1, jitter: { 0 }, now: { Date(timeIntervalSince1970: 0) }))
    let calls = AwaitableLog<Bool>()
    let reader = Task { try await scheduler.read(statusRequest(), scope: "key") { calls.append(true); return statusRead() } }
    try await waitUntil { await scheduler.pendingReadCount == 1 }
    reader.cancel()
    do { _ = try await reader.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    #expect(calls.all.isEmpty)
}

@Test func retryAfterHandlesSecondsDatesInvalidAndUnboundedValues() {
    let now = Date(timeIntervalSince1970: 0)
    func response(_ value: String) -> HTTPURLResponse { statusRead(429, retryAfter: value).response as! HTTPURLResponse }
    #expect(HermesStatusScheduler.retryAfter(response("3"), now: now) == 3)
    #expect(HermesStatusScheduler.retryAfter(response("Thu, 01 Jan 1970 00:00:10 GMT"), now: now) == 10)
    #expect(HermesStatusScheduler.retryAfter(response("-10"), now: now) == 0)
    #expect(HermesStatusScheduler.retryAfter(response("9999"), now: now) == 120)
    #expect(HermesStatusScheduler.retryAfter(response("bogus"), now: now) == nil)
}

@Test(arguments: [false, true]) func exhaustedStatusBackoffKeepsOverviewCalmAndPreservesGoodData(cached: Bool) async throws {
    let (host, session) = MockHermesProtocol.serve { _ in (503, ["error": "nginx busy"]) }
    defer { session.invalidateAndCancel() }
    var backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "fixture-key", session: session)
    backend.statusScheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0, jitter: { 0 }))
    var previous = BotServerInfo()
    if cached { previous.skills = .loaded([]); previous.toolsets = .loaded([]); previous.scope = BotInfoCache.scope(of: backend) }
    let info = await BotInfoCache.fetch(sessionID: nil, using: backend, previous: previous)
    #expect(!info.lastLoadFailed && !info.failedAnything)
    if cached { #expect(info.skills == previous.skills && info.toolsets == previous.toolsets) }
    else { #expect(info.skills == .unavailable(HermesStatusDeferred().localizedDescription)) }
}

@Test func deferredOverviewNeverPreservesAnotherProfilesSnapshot() async throws {
    let (host, session) = MockHermesProtocol.serve { _ in (503, ["error": "busy"]) }
    defer { session.invalidateAndCancel() }
    var backend = HermesBackend(baseURL: URL(string: "https://\(host)/v1")!, apiKey: "fixture-key", session: session)
    backend.statusScheduler = HermesStatusScheduler(timing: .init(tick: .milliseconds(1), spacing: 0, debounce: 0, firstBackoff: 0, jitter: { 0 }))
    var previous = BotServerInfo()
    previous.scope = "another-profile"
    previous.skills = .loaded([.init(name: "private", description: "other profile", category: nil)])
    let info = await BotInfoCache.fetch(sessionID: nil, using: backend, previous: previous)
    #expect(info.skills.value == nil && !info.failedAnything)
}
