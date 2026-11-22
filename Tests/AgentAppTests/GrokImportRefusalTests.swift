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

@MainActor @Test func anAnswerWithNoRowForACachedConversationIsAnUnknownFormatNotAnEmptyHistory() async throws {
    let world = try GrokWorld()
    world.fake.intercept = { index, _ in index == 0 ? .http(200, []) : nil }
    let run = makeRun(world, world.store())
    guard case .stopped(.server(let error)) = await run.start() else {
        Issue.record("the run did not stop")
        return
    }
    #expect(error.reason == .protocolChanged && run.rows.isEmpty)
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
        // Unchanged on purpose: counts and plain words are not credentials.
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
