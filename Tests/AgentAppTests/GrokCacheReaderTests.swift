import Foundation
import Testing
@testable import AgentApp

/// Unpadded lowercase RFC 4648 base32, the way Grok Bot names its cache files (test-only encoder).
private func base32(_ text: String) -> String {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var bits = 0, value = 0, out = ""
    for byte in text.utf8 {
        value = (value << 8) | Int(byte); bits += 8
        while bits >= 5 { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
    }
    if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
    return out
}

private struct Cache {
    let folder = FileManager.default.temporaryDirectory.appending(path: "grok-cache-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    func put(_ key: String, _ json: String) throws { try Data(json.utf8).write(to: folder.appending(path: base32(key) + ".blob")) }
    func roster(_ account: String, rows: String = #"[{"id":"bot-1","name":"One"}]"#) throws {
        try put("sand.client.slice.account.\(account).roster.last-roster", #"{"schemaVersion":4,"value":{"rows":\#(rows)}}"#)
    }
    func transcript(_ account: String, _ id: String,
                    entries: String = #"[{"kind":"notice","id":"n1","seq":1,"text":"synthetic"}]"#) throws {
        try put("sand.client.slice.account.\(account).transcript.replicas.\(id)", #"{"schemaVersion":1,"value":{"entries":\#(entries)}}"#)
    }
    func slot(_ value: String) throws { try put(GrokProtocol.accountSlotKey, #"{"schemaVersion":1,"value":"\#(value)"}"#) }
    func read(account: String? = nil) throws -> GrokCache { try GrokCacheReader(folder: folder).read(account: account) }
}

@Test func readerFindsTheFixtureCacheAndRecordsSchemaVersions() throws {
    let cache = try GrokCacheReader(folder: grokCacheFixture).read()
    #expect(cache.account == "acct-fake-0001" && cache.roster.count == 4 && cache.transcripts.count == 3)
    #expect(cache.rosterSchemaVersion == 4 && cache.transcriptSchemaVersions == [1])
    #expect(cache.skippedFiles == 1)                                          // the ui-layout slice
}

@Test func accountChoiceFollowsTheSlot() throws {
    // Slot present: the segment equal to its percent-encoded value wins over another account's slices.
    let both = try Cache()
    try both.roster("acct%20one%2F1"); try both.transcript("acct%20one%2F1", "bot-1")
    try both.roster("other"); try both.transcript("other", "bot-9")
    #expect(throws: GrokCacheError.needsAccountChoice(accounts: 2)) { try both.read() }   // two segments, no slot
    #expect(try both.read(account: "other").transcripts.keys.sorted() == ["bot-9"])        // the user's choice
    #expect(throws: GrokCacheError.accountMismatch) { try both.read(account: "nobody") }
    try both.slot("acct one/1")
    let chosen = try both.read()
    #expect(chosen.account == "acct%20one%2F1" && chosen.transcripts.keys.sorted() == ["bot-1"] && chosen.skippedFiles == 2)
    // Slot present but naming no segment.
    let mismatched = try Cache()
    try mismatched.roster("acct-a"); try mismatched.slot("acct-b")
    #expect(throws: GrokCacheError.accountMismatch) { try mismatched.read() }
    // Slot absent, one segment.
    let single = try Cache()
    try single.roster("acct-a"); try single.transcript("acct-a", "bot-1")
    #expect(try single.read().account == "acct-a")
    #expect(GrokCacheReader.encodings(of: "a b/c").first == "a%20b%2Fc")
}

@Test func readerGatesOnShapeAndSkipsWhatItMustNotRead() throws {
    let cache = try Cache()
    try cache.roster("a"); try cache.transcript("a", "bot-1")
    try Data("junk".utf8).write(to: cache.folder.appending(path: "!!!.blob"))
    try Data("junk".utf8).write(to: cache.folder.appending(path: "notes.txt"))
    try Data("{}".utf8).write(to: cache.folder.appending(path: "mzxw6==.blob"))
    let outside = FileManager.default.temporaryDirectory.appending(path: "outside-\(UUID().uuidString).blob")
    try Data(#"{"value":{"entries":[]}}"#.utf8).write(to: outside)
    let linked = base32("sand.client.slice.account.a.transcript.replicas.bot-2") + ".blob"
    try FileManager.default.createSymbolicLink(at: cache.folder.appending(path: linked), withDestinationURL: outside)
    let read = try cache.read()
    #expect(read.transcripts.keys.sorted() == ["bot-1"] && read.skippedFiles == 4)
    // A symlinked folder is refused.
    let link = FileManager.default.temporaryDirectory.appending(path: "grok-link-\(UUID().uuidString)")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cache.folder)
    #expect(throws: GrokCacheError.symlinked) { try GrokCacheReader(folder: link).read() }
    #expect(throws: GrokCacheError.notFound) { try GrokCacheReader(folder: cache.folder.appending(path: "missing")).read() }
    // Shape gates: a roster row without a string id, a transcript without `entries`, no roster at all.
    let badRow = try Cache(); try badRow.roster("a", rows: #"[{"id":1}]"#)
    #expect(throws: GrokCacheError.unrecognisedShape) { try badRow.read() }
    let badTranscript = try Cache(); try badTranscript.roster("a")
    try badTranscript.put("sand.client.slice.account.a.transcript.replicas.bot-1", #"{"value":{"rows":[]}}"#)
    #expect(throws: GrokCacheError.unrecognisedShape) { try badTranscript.read() }
    let noRoster = try Cache(); try noRoster.transcript("a", "bot-1")
    #expect(throws: GrokCacheError.noRoster) { try noRoster.read() }
}

private final class FlakyReads: @unchecked Sendable {
    private let lock = NSLock(); private var failures: Int
    init(failures: Int) { self.failures = failures }
    func read(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if GrokBase32.sliceKey(forFileName: url.lastPathComponent)?.contains(".transcript.") == true, failures > 0 {
            failures -= 1; return Data(#"{"value":{"entr"#.utf8)                  // caught mid-write
        }
        return try Data(contentsOf: url)
    }
}

@Test func aBlobCaughtMidWriteIsRetriedOnce() throws {
    let cache = try Cache()
    try cache.roster("a"); try cache.transcript("a", "bot-1")
    let once = FlakyReads(failures: 1)
    #expect(try GrokCacheReader(folder: cache.folder, readFile: once.read).read().transcripts["bot-1"]?.count == 1)
    let twice = FlakyReads(failures: 2)
    #expect(throws: GrokCacheError.blobUnreadable) { try GrokCacheReader(folder: cache.folder, readFile: twice.read).read() }
}

@Test func permissionErrorsMeanCannotReadTheFolder() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
    let eperm = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
    #expect(GrokCacheReader.mapped(eperm, missing: .notFound) == .folderUnreadable)
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    #expect(GrokCacheReader.mapped(denied, missing: .notFound) == .folderUnreadable)
    #expect(GrokCacheReader.mapped(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError), missing: .notFound) == .notFound)
    #expect(GrokCacheError.folderUnreadable.localizedDescription == "\(AppConstants.name) cannot read Grok Bot's folder.")
}

@Test func grokExportSourcesNeverLog() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Sources/AgentApp/GrokExport").standardizedFileURL
    let walk = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    #expect(files.count >= 15)
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for banned in ["print(", "NSLog", "os_log", "Logger", "UserDefaults", "URLSession.shared", "KeychainStore.set"] {
            #expect(!text.contains(banned), "\(file.lastPathComponent) uses \(banned)")
        }
    }
}
