import Foundation
import Testing
@testable import AgentApp

// A refused sign-in and an answer this app cannot read: the run stops with what Grok answered instead of asking
// macOS again for the same sign-in, and a garbled answer is an error, never a crash or an empty "complete" history.

@MainActor private func makeRun(_ world: GrokWorld, _ store: AppStore) -> GrokImportRun {
    GrokImportRun(store: store, environment: world.environment(), options: GrokImportOptions(mode: .full))
}

@MainActor @Test func a401OnTheFirstRequestStopsWithTheRefusalAndAsksMacOSOnce() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index == 0 ? .http(401, Array(#"{"code":"unauthenticated"}"#.utf8)) : nil }
    let run = makeRun(world, world.store())
    let refusal = GrokServerError(.signInInvalid, kind: .list, httpStatus: 401, connectCode: "unauthenticated")
    #expect(await run.start() == .stopped(.server(refusal)))
    #expect(refusal.statusDetail == "HTTP 401, unauthenticated")
    #expect(await run.holder.lifetime == .none)
    #expect(world.passwords.reads == 1 && run.rows.isEmpty)
    #expect(await run.requestCount() == 1)
    // What Grok said travels with the refusal, as plain words, for the screen.
    world.fake.intercept = { _, _ in .http(401, Array(#"{"code":"unauthenticated","message":"Needs a plan, see https://x.y/z"}"#.utf8)) }
    guard case .stopped(.server(let said)) = await makeRun(world, world.store()).start() else { Issue.record("did not stop"); return }
    #expect(said.serverMessage == "Needs a plan see" && said.saidSentence == " Grok said: “Needs a plan see”.")
}

@MainActor @Test func aRenewedSignInRefusedOnItsFirstRequestStopsInsteadOfPausingAgain() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index >= 2 ? .http(401, []) : nil }
    let run = makeRun(world, world.store())
    // The canary and Jarvis's page were accepted, so the first 401 is a sign-in that ran out: pause, Continue.
    #expect(await run.start() == .paused(.signInInvalid))
    // The sign-in read again is refused before it was ever accepted: asking a third time cannot help.
    #expect(await run.retryRemaining() == .stopped(.server(GrokServerError(.signInInvalid, kind: .list, httpStatus: 401))))
    #expect(world.passwords.reads == 2 && run.rows.count == 1)
    #expect(await run.requestCount() == 4)
}

@MainActor private func fallingBack(_ world: GrokWorld) -> GrokImportRun {
    GrokImportRun(store: world.store(), environment: world.environment(),
                  options: GrokImportOptions(mode: .full, fallsBackToRecent: true))
}

@MainActor @Test func aRefusedRequestSendsEveryChatStillQueuedToTheCacheWhenTheRunMayFallBack() async throws {
    let world = try GrokWorld()
    // The canary and Jarvis's page are answered; from Finance on Grok says the request is not allowed.
    world.fake.intercept = { index, _ in index >= 2 ? .http(403, []) : nil }
    var events: [String] = []
    let run = fallingBack(world)
    run.onEvent = { if case .fellBack(let error, let wholeRun) = $0 { events.append("\(error.description) \(wholeRun)") } }
    #expect(await run.start() == .finished)
    #expect(run.fallback == GrokServerError(.rejected, kind: .list, httpStatus: 403) && events == ["list rejected HTTP 403 true"])
    #expect(run.rows.count == 4 && run.rows[0].coverage != .cacheOnly && run.rows[0].status == .done)
    // The cache's lines are saved, but All history was asked for: those chats are not done.
    #expect(run.rows.dropFirst().allSatisfy { $0.coverage == .cacheOnly && $0.status == .incomplete })
    #expect(await run.holder.lifetime == .none)
    #expect(await run.requestCount() == 3)

    // Without the option the same stop ends the run, as the commands expect.
    let other = try GrokWorld()
    other.fake.intercept = { index, _ in index >= 2 ? .http(403, []) : nil }
    let plain = GrokImportRun(store: other.store(), environment: other.environment(), options: GrokImportOptions(mode: .full))
    #expect(await plain.start() == .stopped(.server(GrokServerError(.rejected, kind: .list, httpStatus: 403))))
    #expect(plain.fallback == nil && plain.rows.count == 1)
}

@MainActor @Test func aStopInsideOneChatSendsOnlyThatChatToTheCache() async throws {
    let world = try GrokWorld()
    // Only Finance's page is refused, and not as a matter of the sign-in.
    world.fake.intercept = { index, _ in index == 2 ? .http(400, []) : nil }
    let run = fallingBack(world)
    #expect(await run.start() == .finished)
    #expect(run.fallback == nil && run.rows.count == 4)
    #expect(run.rows[1].coverage == .cacheOnly && run.rows[1].status == .incomplete)
    #expect(run.rows[0].coverage != .cacheOnly && run.rows[2].coverage != .cacheOnly && run.rows[3].coverage != .cacheOnly)
    #expect(await run.requestCount() == 5)
}

@MainActor @Test func twoChatsStoppedInARowSendTheRestToTheCacheToo() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index >= 2 ? .http(400, []) : nil }
    let run = fallingBack(world)
    #expect(await run.start() == .finished)
    #expect(run.fallback == GrokServerError(.rejected, kind: .list, httpStatus: 400))
    #expect(run.rows.dropFirst().allSatisfy { $0.coverage == .cacheOnly && $0.status == .incomplete })
    // Finance and Plain were asked for; the group was not.
    #expect(await run.requestCount() == 4)
}

@MainActor @Test func tooManyRequestsPausesInsteadOfStoppingOrFallingBack() async throws {
    let world = try GrokWorld()
    let busy = GrokSwitch()
    busy.isOn = true
    world.fake.intercept = { index, _ in busy.isOn && index == 2 ? .http(429, []) : nil }
    let run = fallingBack(world)
    #expect(await run.start() == .paused(.network(GrokServerError(.rejected, kind: .list, httpStatus: 429))))
    busy.isOn = false
    #expect(await run.retryRemaining() == .finished)
    #expect(run.fallback == nil && run.rows.allSatisfy { $0.status == .done })
}

@Test func onlyLastingRefusalsEndAllHistoryOrAreRemembered() {
    let refused = GrokServerError(.signInInvalid, kind: .list, httpStatus: 401)
    let forbidden = GrokServerError(.rejected, kind: .presign, httpStatus: 403)
    let oneFile = GrokServerError(.rejected, kind: .blob, httpStatus: 403)
    let ceiling = GrokServerError(.requestCeiling, kind: .list)
    let busy = GrokServerError(.rejected, kind: .list, httpStatus: 429)
    let unreadable = GrokServerError(.protocolChanged, kind: .list)
    #expect(refused.endsFullHistory && refused.isLastingRefusal)
    #expect(forbidden.endsFullHistory && forbidden.isLastingRefusal)
    #expect(!oneFile.endsFullHistory && !oneFile.isLastingRefusal)
    #expect(ceiling.endsFullHistory && !ceiling.isLastingRefusal)
    #expect(!busy.endsFullHistory && !busy.isLastingRefusal && busy.isTransientRefusal)
    #expect(!unreadable.endsFullHistory && unreadable.isLastingRefusal && !unreadable.isTransientRefusal)
}

@Test func theRememberedStopLapsesAfterAWeekOrWithAnotherAccount() {
    let defaults = isolatedDefaults()
    let then = Date(timeIntervalSince1970: 1_800_000_000), soon = then.addingTimeInterval(3600)
    GrokRefusalNote(date: then, summary: "Grok said no.", account: "a").save(defaults)
    #expect(GrokRefusalNote.load(defaults, now: soon, account: "a")?.summary == "Grok said no.")
    #expect(GrokRefusalNote.load(defaults, now: soon, account: nil) != nil)
    #expect(GrokRefusalNote.load(defaults, now: soon, account: "b") == nil)
    #expect(defaults.data(forKey: GrokRefusalNote.key) == nil)
    GrokRefusalNote(date: then, summary: "Grok said no.", account: "a").save(defaults)
    #expect(GrokRefusalNote.load(defaults, now: then.addingTimeInterval(8 * 24 * 3600), account: "a") == nil)
    #expect(defaults.data(forKey: GrokRefusalNote.key) == nil)
}

@MainActor @Test func twoCachedChatsAnsweringWithNoRowAreAnUnknownFormatOneIsNot() async throws {
    // One chat this Mac holds entries of answers with no row: it may have been cleared on Grok's side. The next one
    // answers normally, so the import goes on.
    let cleared = try GrokWorld()
    cleared.fake.intercept = { index, _ in index == 0 ? .http(200, []) : nil }
    let first = makeRun(cleared, cleared.store())
    #expect(await first.start() == .finished)
    #expect(first.rows.count == 4)

    // Two in a row: an answer this app cannot read, and nothing is written.
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index <= 1 ? .http(200, []) : nil }
    let run = makeRun(world, world.store())
    guard case .stopped(.server(let error)) = await run.start() else {
        Issue.record("the run did not stop")
        return
    }
    #expect(error.reason == .protocolChanged && run.rows.isEmpty)
    #expect(await run.requestCount() == 2)
}

@Test func aGarbledAnswerThrowsInsteadOfCrashing() {
    // A length of 2^64 - 1, and one of 2^63 - 1: both used to trap on the way to the bounds check.
    let huge: [UInt8] = [0x0A] + [UInt8](repeating: 0xFF, count: 9) + [0x01]
    let nearMax: [UInt8] = [0x0A] + [UInt8](repeating: 0xFF, count: 8) + [0x7F]
    #expect(throws: GrokProtobufError.lengthOverflow) { _ = try GrokProtobuf.parse(huge) }
    #expect(throws: GrokProtobufError.lengthOverflow) { _ = try GrokProtobuf.parse(nearMax) }
    // A row that carries a kind and no sequence number.
    let row = GrokProtobuf.bytesField(1, GrokProtobuf.bytesField(2, Array("message".utf8)))
    #expect(throws: GrokProtobufError.rowWithoutSeq) { _ = try GrokProtobuf.decodeListResponse(row) }
    // A negative cursor encodes instead of trapping.
    #expect(!GrokProtobuf.encodeListRequest(agentID: "a", limit: 1, beforeSeq: -1).isEmpty)
}

@Test func tokenFactsCarryLifetimeAndKeyNameAndNothingElse() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func part(_ object: [String: Any]) -> String {
        GrokChecksum.base64URLNoPadding([UInt8](try! JSONSerialization.data(withJSONObject: object)))
    }
    let claims: [String: Any] = ["exp": 1_800_000_600, "iat": 1_799_999_000, "iss": "https://auth.example.com/",
                                 "type": "session", "sub": "user|secret-subject", "email": "someone@example.com"]
    let facts = GrokCredentials.tokenFacts("\(part(["alg": "ES256", "kid": "key-1"])).\(part(claims)).signature", now: now)
    #expect(facts == GrokTokenFacts(expPresent: true, secondsToExpiry: 600, issuedSecondsAgo: 1000, algorithm: "ES256",
                                    keyID: "key-1", issuerHost: "auth.example.com", tokenType: "session"))
    #expect(GrokCredentials.tokenFacts("not-a-token", now: now) == GrokTokenFacts())
}

@Test func diagnosticMessageKeepsShortWordsAndDropsAnythingTokenLike() {
    let token = String(repeating: "a", count: 40)
    let body = Array(#"{"code":"unauthenticated","message":"Token \#(token) expired, sign in again: https://x.y/z?k=\#(token)"}"#.utf8)
    #expect(GrokServerError.diagnosticMessage(fromBody: body) == "Token expired sign in again")
    let refusal = Array(#"{"code":"unauthenticated","message":"Grok Bot requires an Ultra subscription or a Premium self-serve team seat"}"#.utf8)
    #expect(GrokServerError.diagnosticMessage(fromBody: refusal) == "Grok Bot requires an Ultra subscription or a Premium self-serve team seat")
    #expect(GrokServerError.diagnosticMessage(fromBody: Array(#"{"message":"echo Bearer abc"}"#.utf8)) == nil)
    #expect(GrokServerError.diagnosticMessage(fromBody: Array(#"{"message":"id 12345 key abc123 ok"}"#.utf8)) == "id key ok")
    #expect(GrokServerError.diagnosticMessage(fromBody: Array("not json".utf8)) == nil)
}

// MARK: Redaction and the archive

@Test func redactionCoversQuotedKeysEnvNamesAndQuotedValues() {
    let vectors: [(String, String)] = [
        (#"{"password": "hunter2"}"#, #"{"[REDACTED]}"#),
        ("**Password**: hunter2", "**[REDACTED]"),
        (#"password: "correct horse battery staple" then more"#, "[REDACTED] then more"),
        ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI", "AWS_[REDACTED]"),
        ("passwd=abc def", "[REDACTED] def"),
        ("key xai-ABCDEFGHIJKLMNOP1234 end", "key [REDACTED] end"),
        ("**Password:** hunter2", "**[REDACTED]"),
        ("password: `correct horse` ok", "[REDACTED] ok"),
        ("password: “correct horse” ok", "[REDACTED] ok"),
        (#"secret: "a\"b c" tail"#, "[REDACTED] tail"),
        // The gap between two string literals in code is not a quoted value.
        (#"print("Password: " + pw + " is wrong")"#, #"print("[REDACTED] + pw + " is wrong")"#),
        // Unchanged on purpose: counts, paths and plain words are not credentials.
        ("PWD=/home/user and pwd: /tmp", "PWD=/home/user and pwd: /tmp"),
        ("passwd: files", "passwd: files"),
        ("/etc/passwd: No such file", "/etc/passwd: No such file"),
        ("XAI_MANAGEMENT_KEY and xai_shap_values_plot(x)", "XAI_MANAGEMENT_KEY and xai_shap_values_plot(x)"),
        (#""prompt_tokens": 12, "max_tokens": 4096"#, #""prompt_tokens": 12, "max_tokens": 4096"#),
        ("token_count: 5", "token_count: 5"),
        ("secretary: Ann", "secretary: Ann"),
    ]
    for (text, expected) in vectors { #expect(SecretFilter.redacted(text, replacement: "[REDACTED]") == expected) }
}

@Test func mergingPutsSavedLinesThroughTodaysFilter() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "grok-refilter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "bot.json")
    let saved = ArchivedMessage(id: "m1", seq: 1, role: "assistant", author: nil, text: #"use {"password": "hunter2"} here"#,
                                timestamp: nil, hidden: false, channel: "chat", to: nil)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(GrokHistoryFile(sourceID: "source", messages: [saved])).write(to: url)
    let merged = try GrokHistoryStore.mergeOnDisk([], sourceID: "source", url: url, directory: directory)
    #expect(merged.count == 1 && merged[0].text == #"use {"[REDACTED]} here"#)
}

@Test func aCopyThatIsShorterOnlyBecauseMoreWasRedactedReplacesTheSavedLine() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "grok-residue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "bot.json")
    func line(_ id: String, _ seq: Int64, _ text: String) -> ArchivedMessage {
        ArchivedMessage(id: id, seq: seq, role: "assistant", author: nil, text: text, timestamp: nil, hidden: false, channel: "chat", to: nil)
    }
    // What an older filter left: the first word of a quoted value gone, the rest still there.
    let saved = [line("m1", 1, #"it is [REDACTED] horse battery staple" for now"#), line("m2", 2, "a long settled answer")]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(GrokHistoryFile(sourceID: "source", messages: saved)).write(to: url)
    let incoming = [line("m1", 1, "it is [REDACTED] for now"), line("m2", 2, "a long")]
    let merged = try GrokHistoryStore.mergeOnDisk(incoming, sourceID: "source", url: url, directory: directory)
    // The cleaner copy wins; an ordinary shorter copy still does not.
    #expect(merged.map(\.text) == ["it is [REDACTED] for now", "a long settled answer"])
}
