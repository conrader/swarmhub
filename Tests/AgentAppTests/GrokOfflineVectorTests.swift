import Foundation
import Testing
@testable import AgentApp

// Known-answer vectors from briefs/P10.md ("Facts"), recomputed from the repo's Python on 2026-10-13.

@Test func redactionVectorsMatchTheScript() {
    let vectors: [(String, String)] = [
        ("Hi! Use Bearer FAKETOKENVALUE1234 nowhere.", "Hi! Use [REDACTED] nowhere."),
        ("Synthetic orchestrator. api_key=FAKEFAKE1234", "Synthetic orchestrator. [REDACTED]"),
        ("x -----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n", "x [REDACTED]"),
        ("https://user:pw@example.invalid", "https[REDACTED]example.invalid"),
        ("Authorization: Basic dXNlcjpwYXNz", "[REDACTED]"),
        ("Basic aGVsbG8=", "Basic aGVsbG8="),
        ("token: abc token=def", "[REDACTED] [REDACTED]"),
        ("password: token: abc", "[REDACTED] abc"),
        ("AKIAABCDEFGHIJKLMNOP", "[REDACTED]"),
        ("plain words", "plain words"),
    ]
    for (input, expected) in vectors {
        var redact = GrokRedactor()
        #expect(redact(input) == expected, "\(input)")
    }
}

@Test func redactionCountsUseTheScriptsCategories() {
    var redact = GrokRedactor()
    _ = redact("Hi! Use Bearer FAKETOKENVALUE1234 nowhere.")
    _ = redact("Synthetic orchestrator. api_key=FAKEFAKE1234")
    _ = redact("Basic dXNlcjpwYXNz and Basic aGVsbG8=")
    _ = redact("token: abc token=def")
    #expect(redact.counts == ["bearer": 1, "credential_assignment": 3, "basic_auth": 1])
    #expect(redact.total == 5)
    #expect(GrokRedactor.categories.count == GrokTemplateParser.secretValuePatterns.count)
    // Template import keeps its own filter and replacement.
    #expect(GrokTemplateParser.redactSecrets("api_key=FAKEFAKE1234").text == "[removed]")
}

@Test func hiddenMarkerIsTestedOnRedactedText() {
    #expect(GrokRedactor.hasHiddenMarker("[GROK_BOT_HIDDEN_PROMPT] x"))
    #expect(GrokRedactor.hasHiddenMarker("a [GROK_BOT_HIDDEN] b"))
    #expect(!GrokRedactor.hasHiddenMarker("[GROK_BOT_HIDDEN-x]"))
}

@Test func slugAndProfileVectors() {
    let vectors: [(String, String, String)] = [
        ("Finance Controller", "finance-controller", "finance-controller"),
        ("  Finance  Controller ", "finance-controller", "finance--controller"),
        ("R&D Bot", "r-d-bot", "r&d-bot"),
        ("Zoë Ünder", "zo-nder", "zoë-ünder"),
        ("", "bot", ""),
    ]
    for (name, slug, profileSlug) in vectors {
        #expect(GrokNaming.slugify(name) == slug, "\(name)")
        #expect(GrokNaming.profileSlug(name) == profileSlug, "\(name)")
    }
    #expect(GrokNaming.profile(forName: "Finance Controller") == "grok-finance-controller")
    #expect(GrokNaming.profile(forName: "  Finance  Controller ") == "grok-finance--controller")
    #expect(GrokNaming.profile(forName: "R&D Bot") == "grok-r-d-bot")        // profile_slug is not a valid profile name
    #expect(GrokNaming.profile(forName: "Zoë Ünder") == "grok-zo-nder")
    #expect(GrokNaming.profile(forName: "") == "grok-bot")
}

@Test func isoUsesIntegerArithmetic() {
    #expect(GrokNaming.iso(1_760_000_008_123) == "2025-10-09T08:53:28.123Z")
    #expect(GrokNaming.iso(1_760_000_002_000) == "2025-10-09T08:53:22.000Z")
    #expect(GrokNaming.iso(0) == "1970-01-01T00:00:00.000Z")
    #expect(GrokNaming.iso(951_782_400_999) == "2000-02-29T00:00:00.999Z")
    #expect(GrokNaming.iso(-1) == "1969-12-31T23:59:59.999Z")
}

@Test func base32NamesDecodeAndRejectBadStems() throws {
    let fixtures = try FileManager.default.contentsOfDirectory(atPath: grokCacheFixture.path)
    let keys = fixtures.compactMap(GrokBase32.sliceKey(forFileName:))
    #expect(keys.count == 5)
    #expect(keys.filter { $0.hasSuffix(GrokProtocol.rosterSuffix) } == ["sand.client.slice.account.acct-fake-0001.roster.last-roster"])
    #expect(keys.contains("sand.client.slice.ui-layout"))
    #expect(GrokBase32.sliceKey(forFileName: "!!!.blob") == nil)
    #expect(GrokBase32.sliceKey(forFileName: "onqw4zbo.json") == nil)
    #expect(GrokBase32.decode("mzxw6") == "foo")
    #expect(GrokBase32.decode("mzxw6ytb") == "fooba")
    #expect(GrokBase32.decode("MZXW6") == nil)          // uppercase is not what Grok Bot writes
    #expect(GrokBase32.decode("mzxw6===") == nil)       // no padding
    for stem in ["m", "mzx", "mzxw6y"] { #expect(GrokBase32.decode(stem) == nil, "\(stem)") } // lengths 1, 3, 6 mod 8
    #expect(GrokBase32.decode("74") == nil)             // 0xFF is not UTF-8
}

@Test func jsonValueKeepsBoolIntAndDoubleApart() throws {
    let value = try GrokJSON.parse(Data(#"{"a":1,"b":1.0,"c":true,"d":null,"e":"xé😀","f":[1e2,-0],"a":2}"#.utf8))
    #expect(value["a"] == .int(2))                      // a repeated key keeps the last value
    #expect(value["b"] == .double(1) && value["b"]?.intValue == nil)
    #expect(value["c"] == .bool(true) && value["c"]?.intValue == nil)
    #expect(value["d"] == .null && value["d"]?.isNull == true && value["zz"] == nil)
    #expect(value["e"]?.stringValue == "xé😀")
    #expect(value["f"] == .array([.double(100), .int(0)]))
    for bad in ["{", "[1,]", "01", "\"\u{01}\"", "tru", "1 2", "{\"a\" 1}"] {
        #expect(throws: GrokJSONError.self) { try GrokJSON.parse(Data(bad.utf8)) }
    }
    let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
    #expect(throws: GrokJSONError.tooDeep) { try GrokJSON.parse(Data(deep.utf8)) }
}

@Test func entryMergeAndCoverage() throws {
    func entry(_ seq: Int64, _ id: String, streaming: Bool? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["seq": .int(seq), "id": .string(id)]
        if let streaming { object["isStreaming"] = .bool(streaming) }
        return .object(object)
    }
    let fetched = [entry(1, "s1"), entry(2, "s2"), entry(4, "s4"), entry(5, "s5")]
    let cached = [entry(4, "c4"), entry(5, "c5", streaming: true), entry(7, "c7"), .object(["seq": .double(8), "id": .string("bad")])]
    let merged = GrokEntryMerge.merge(cached: cached, fetched: fetched)
    #expect(merged.compactMap { $0["id"]?.stringValue } == ["s1", "s2", "c4", "s5", "c7"])
    let coverage = GrokEntryMerge.coverage(merged)
    #expect(coverage == .init(min: 1, max: 7, count: 5, gaps: [[3, 3], [6, 6]], complete: false))
    #expect(GrokEntryMerge.coverage([]).complete == false)
    // A fetched body: the row's seq wins; the id is the body's, else the row's entry_id.
    let body = Array(#"{"seq":99,"kind":"notice","text":"t"}"#.utf8)
    #expect(GrokEntryMerge.entry(body: body, seq: 3, entryID: "row-3")?["seq"] == .int(3))
    #expect(GrokEntryMerge.entry(body: body, seq: 3, entryID: "row-3")?["id"] == .string("row-3"))
    #expect(GrokEntryMerge.entry(body: Array(#"{"id":"own"}"#.utf8), seq: 3, entryID: "row-3")?["id"] == .string("own"))
    #expect(GrokEntryMerge.entry(body: Array("[1]".utf8), seq: 3, entryID: nil) == nil)
    #expect(GrokBundleBuilder.gapLimitations([[11, 11], [300, 301]]) == ["Grok's server returned no entries for seq 11, 300-301."])
    let many = (1...22).map { [Int64($0 * 2), Int64($0 * 2)] }
    #expect(GrokBundleBuilder.gapLimitations(many).first?.hasSuffix("44. (and 2 more gaps)") == false)
    #expect(GrokBundleBuilder.gapLimitations(many).first?.hasSuffix("40. (and 2 more gaps)") == true)
}
