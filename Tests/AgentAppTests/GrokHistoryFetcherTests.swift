import Foundation
import Testing
@testable import AgentApp

// P10b: paging, blob and omitted resolution, merge and coverage against FakeGrok (mirrors FetchTests in
// scripts/test_grokbot_server.py). Never contacts Grok.

private let alpha = "00000000-0000-4000-8000-0000000000a1"

/// History seqs 1…1200 without 300 and 301; blob rows 10, 11, 999; omitted rows 500 and 7; blob 11 gone.
private func standardFake() -> FakeGrok {
    let fake = FakeGrok()
    let seqs = (1...1200).map(Int64.init).filter { $0 != 300 && $0 != 301 }
    fake.history = [alpha: Dictionary(uniqueKeysWithValues: seqs.map { ($0, FakeGrok.entry($0)) })]
    fake.blobSeqs = [10, 11, 999]
    fake.omittedSeqs = [500, 7]
    fake.goneBlobs = ["\(alpha)-s11"]
    return fake
}

private func seqs(_ entries: [JSONValue]) -> [Int64] { entries.compactMap { $0["seq"]?.intValue }.sorted() }

@Test func pagesBackToSeqOneWithBlobsAndOmittedRows() async throws {
    let fake = standardFake()
    let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: 1150)
    let expected = (1...1149).map(Int64.init).filter { ![11, 300, 301].contains($0) }
    #expect(result.stop == nil)
    #expect(result.reachedStart)
    #expect(seqs(result.entries) == expected)
    #expect(result.stats == .init(pages: 3, rows: 1147, blobsRead: 2, blobsMissing: 1, omittedRefetched: 2, unreadable: 1))
    #expect(result.entries.first { $0["seq"] == .int(500) }?["content"] == .string("synthetic 500"))
    #expect(result.entries.first { $0["seq"] == .int(999) }?["id"] == .string("e999"))

    let posts = fake.requests.filter { $0.method == "POST" }
    #expect(Set(posts.map { URL(string: $0.url)!.path }) == ["/aiserver.v1.GrokBotService/ListGrokBotTranscriptEntries",
                                                              "/aiserver.v1.GrokBotService/PresignSandBoxStoreReads"])
    #expect(posts.allSatisfy { $0.headers["authorization"] == "Bearer \(GrokFixtureSecrets.token)" })
    let gets = fake.requests.filter { $0.method == "GET" }
    #expect(gets.count == 3)
    #expect(gets.allSatisfy { URL(string: $0.url)!.path.hasPrefix("/blob/") && $0.headers["authorization"] == nil })
    #expect(Set(fake.requests.map(\.method)) == ["GET", "POST"])

    // Merged with the cached newest entries 1149…1200 (cached text wins): gaps 11 and 300–301, 1,197 messages.
    let cached = (1149...1200).map { GrokJSON.from(FakeGrok.entry(Int64($0), "cached \($0)")) }
    let merged = GrokHistoryMerge.merge(cached: cached, fetched: result)
    #expect(merged.entries.count == 1197)
    #expect(merged.coverage == .serverGaps([[11, 11], [300, 301]]))
    #expect(merged.entries.first { $0["seq"] == .int(1149) }?["content"] == .string("cached 1149"))
    var redactor = GrokRedactor(), stats = GrokBundleV1.Statistics()
    let mapped = GrokEntryMapper(names: [:], botName: "Alpha").map(merged.entries, redact: &redactor, stats: &stats)
    #expect(mapped.messages.count == 1197)
}

@Test func aServerCappedAt100RowsPerPageStillReachesSeqOne() async {
    let fake = standardFake()
    fake.pageCap = 100
    let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: 1150)
    #expect(result.reachedStart)
    #expect(seqs(result.entries).first == 1)
    #expect(result.entries.count == 1146)
    #expect(result.stats.pages == 12)
}

@Test func aSeqOneGapCostsOneExtraEmptyRequest() async {
    let fake = FakeGrok()
    fake.history = [alpha: Dictionary(uniqueKeysWithValues: (2...5).map { (Int64($0), FakeGrok.entry(Int64($0))) })]
    let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: nil)
    #expect(result.reachedStart)
    #expect(result.stats.pages == 2)
    #expect(GrokHistoryMerge.merge(cached: [], fetched: result).coverage == .serverGaps([[1, 1]]))
}

@Test func aServerThatIgnoresTheCursorIsProtocolChanged() async {
    let fake = standardFake()
    fake.ignoresCursor = true
    fake.omittedSeqs = []
    fake.blobSeqs = []
    let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: 1150)
    #expect(result.stop == .failed(GrokServerError(.protocolChanged, kind: .list, errorType: "CursorIgnored")))
    #expect(!result.reachedStart)
    #expect(result.stats.pages == 2)
    #expect(GrokHistoryMerge.merge(cached: [], fetched: result).coverage == .incomplete(stoppedAt: 701, gaps: []))
}

@Test func thePageCeilingStopsAsIncompleteWithAResumeCursor() async {
    let fake = standardFake()
    fake.pageCap = 100
    var fetcher = GrokHistoryFetcher(client: fake.client())
    fetcher.maxPages = 2
    let result = await fetcher.fetchOlder(agentID: alpha, beforeSeq: 1150)
    #expect(result.stop == .pageCeiling)
    #expect(result.stats.pages == 2)
    #expect(result.nextBeforeSeq == 950)
    let merged = GrokHistoryMerge.merge(cached: [], fetched: result)
    #expect(merged.coverage == .incomplete(stoppedAt: 950, gaps: []))
    // Resuming from the cursor finishes the rest.
    let rest = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: result.nextBeforeSeq)
    #expect(rest.reachedStart)
    #expect(Set(seqs(result.entries)).union(seqs(rest.entries)).count == 1146)
}

@Test func theRequestCeilingStopsTheFetch() async {
    let fake = standardFake()
    var limits = GrokRPCClient.Limits()
    limits.maxRequests = 3
    let result = await GrokHistoryFetcher(client: fake.client(limits: limits)).fetchOlder(agentID: alpha, beforeSeq: 1150)
    #expect(result.stop == .failed(GrokServerError(.requestCeiling, kind: .list)))
    // Page 1 (list, presign, blob 999) fits; the list request for page 2 is the fourth and is never sent.
    #expect(fake.requests.count == 3)
    #expect(result.entries.count == 500)
    #expect(result.nextBeforeSeq == 650)
}

@Test func cancellationBetweenRequestsStopsAfterTheInFlightPage() async {
    let fake = standardFake()
    let fetcher = GrokHistoryFetcher(client: fake.client())
    let result = await Task {
        await fetcher.fetchOlder(agentID: alpha, beforeSeq: 1150) { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
    }.value
    #expect(result.stop == .cancelled)
    #expect(result.stats.pages == 1)
    #expect(result.nextBeforeSeq == 650)
    #expect(result.entries.count == 500)
    // Page 1 (1149…650): list, presign, one blob GET (999). Nothing after the cancel.
    #expect(fake.requests.count == 3)
}

@Test func failuresMidPageKeepEarlierPagesAndTheCursor() async {
    let fake = standardFake()
    fake.intercept = { index, _ in index >= 3 ? .http(503, []) : nil }
    let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: 1150)
    #expect(result.stop == .failed(GrokServerError(.unavailable, kind: .list, httpStatus: 503)))
    #expect(result.entries.count == 500)
    #expect(result.nextBeforeSeq == 650)
    #expect(fake.requests.count == 7)
}

@Test func blobURLsThatAreNotPublicHTTPSStopTheFetchUncontacted() async {
    for bad in ["http://blobs.example.test/x", "https://localhost/x", "https://10.1.2.3/x"] {
        let fake = standardFake()
        fake.blobURLOverride = { _ in bad }
        let result = await GrokHistoryFetcher(client: fake.client()).fetchOlder(agentID: alpha, beforeSeq: 1150)
        #expect(result.stop == .failed(GrokServerError(.blobURLRejected, kind: .blob)))
        #expect(fake.requests.allSatisfy { $0.method == "POST" })
    }
}

@Test func coverageIsThreeValued() {
    let full = GrokHistoryFetcher.Result(entries: (1...3).map { GrokJSON.from(FakeGrok.entry(Int64($0))) }, reachedStart: true)
    #expect(GrokHistoryMerge.merge(cached: [], fetched: full).coverage == .complete)
    var partial = GrokHistoryFetcher.Result(entries: [10, 12, 13, 20].map { GrokJSON.from(FakeGrok.entry($0)) })
    partial.oldestFetched = 10
    partial.stop = .cancelled
    // Below seq 10 nothing was fetched: that is "incomplete", never a server gap; 11 and 14–19 are.
    #expect(GrokHistoryMerge.merge(cached: [], fetched: partial).coverage == .incomplete(stoppedAt: 10, gaps: [[11, 11], [14, 19]]))
    let nothing = GrokHistoryFetcher.Result(stop: .failed(GrokServerError(.network, kind: .list)))
    let cachedOnly = [GrokJSON.from(FakeGrok.entry(40)), GrokJSON.from(FakeGrok.entry(42))]
    #expect(GrokHistoryMerge.merge(cached: cachedOnly, fetched: nothing).coverage == .incomplete(stoppedAt: 40, gaps: [[41, 41]]))
}
