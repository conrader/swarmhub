import Foundation

enum GrokCacheError: Error, Equatable, LocalizedError {
    case notFound
    case folderUnreadable
    case symlinked
    case noRoster
    case blobUnreadable
    case unrecognisedShape
    case needsAccountChoice(accounts: Int)
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .notFound: "Grok Bot's data folder was not found on this Mac."
        case .folderUnreadable: "\(AppConstants.name) cannot read Grok Bot's folder."
        case .symlinked: "Grok Bot's cache folder is a link; \(AppConstants.name) reads only the real folder."
        case .noRoster: "Grok Bot's cache has no bot list yet. Open Grok Bot once and sign in."
        case .blobUnreadable: "A Grok Bot cache file could not be read (Grok Bot may be writing it). Try again in a moment."
        case .unrecognisedShape: "\(AppConstants.name) cannot read this version of Grok Bot's data."
        case .needsAccountChoice(let accounts): "Grok Bot's cache holds \(accounts) accounts; \(AppConstants.name) imports one Grok account at a time."
        case .accountMismatch: "Grok Bot's cache does not belong to the signed-in account."
        }
    }
}

/// What the local cache holds for one account: the roster rows and each conversation's cached entries.
struct GrokCache: Sendable {
    /// Percent-encoded account segment of the slice keys.
    var account: String
    /// Rows with a string `id`, in the roster's order.
    var roster: [[String: JSONValue]]
    /// Conversation id → cached entries, as Grok Bot stored them (newest 28–200).
    var transcripts: [String: [JSONValue]]
    /// Recorded, never gated on: drift is detected by shape.
    var rosterSchemaVersion: Int64?
    var transcriptSchemaVersions: Set<Int64>
    /// Links, non-`.blob` and undecodable names, and slices of other kinds: never read.
    var skippedFiles: Int
}

/// Reads `sand-client-persistence/*.blob` read-only (port of `load_cache` with stricter gates; briefs/P10.md P10a 4).
/// Never prompts, never writes, never follows a link.
struct GrokCacheReader: Sendable {
    static let maximumBlobBytes = 64 * 1024 * 1024
    typealias ReadFile = @Sendable (URL) throws -> Data

    let folder: URL
    let readFile: ReadFile

    init(folder: URL, readFile: @escaping ReadFile = { try Data(contentsOf: $0) }) {
        self.folder = folder
        self.readFile = readFile
    }

    /// `account`: a segment the user chose when the cache holds several and no slot names one.
    func read(account chosen: String? = nil) throws -> GrokCache {
        let names = try listFolder()
        var slices: [(name: String, key: String)] = []
        var skipped = 0
        var slotValue: String?
        for name in names.sorted() {
            guard let key = GrokBase32.sliceKey(forFileName: name), !isLink(name) else { skipped += 1; continue }
            if key == GrokProtocol.accountSlotKey {
                slotValue = try? slot(from: blob(name))
            } else if key.hasPrefix(GrokProtocol.accountSlicePrefix), Self.parse(key) != nil {
                slices.append((name, key))
            } else {
                skipped += 1
            }
        }
        let segments = Set(slices.compactMap { Self.parse($0.key)?.account })
        let account = try Self.chooseAccount(segments: segments, slot: slotValue, chosen: chosen)
        var cache = GrokCache(account: account, roster: [], transcripts: [:], rosterSchemaVersion: nil,
                              transcriptSchemaVersions: [], skippedFiles: skipped)
        var sawRoster = false
        for slice in slices {
            guard let parsed = Self.parse(slice.key), parsed.account == account else { cache.skippedFiles += 1; continue }
            let root = try blob(slice.name)
            guard let value = root["value"]?.objectValue else { throw GrokCacheError.unrecognisedShape }
            if let conversation = parsed.conversation {
                guard let entries = value["entries"]?.arrayValue else { throw GrokCacheError.unrecognisedShape }
                cache.transcripts[conversation] = entries
                if let version = root["schemaVersion"]?.intValue { cache.transcriptSchemaVersions.insert(version) }
            } else {
                guard let rows = value["rows"]?.arrayValue else { throw GrokCacheError.unrecognisedShape }
                cache.roster = try rows.map { row in
                    guard let object = row.objectValue, object["id"]?.stringValue != nil else { throw GrokCacheError.unrecognisedShape }
                    return object
                }
                cache.rosterSchemaVersion = root["schemaVersion"]?.intValue
                sawRoster = true
            }
        }
        guard sawRoster else { throw GrokCacheError.noRoster }
        return cache
    }

    // MARK: Keys

    /// `sand.client.slice.account.<account>.roster.last-roster` or `….<account>.transcript.replicas.<id>`; the id is
    /// the text after the last dot, as `rsplit(".", 1)` takes it.
    static func parse(_ key: String) -> (account: String, conversation: String?)? {
        guard key.hasPrefix(GrokProtocol.accountSlicePrefix) else { return nil }
        let rest = key.dropFirst(GrokProtocol.accountSlicePrefix.count)
        if rest.hasSuffix(GrokProtocol.rosterSuffix) {
            let account = String(rest.dropLast(GrokProtocol.rosterSuffix.count))
            return account.isEmpty ? nil : (account, nil)
        }
        guard let infix = rest.range(of: GrokProtocol.transcriptInfix, options: .backwards) else { return nil }
        let account = String(rest[..<infix.lowerBound])
        guard let lastDot = key.lastIndex(of: ".") else { return nil }
        let conversation = String(key[key.index(after: lastDot)...])
        return account.isEmpty || conversation.isEmpty ? nil : (account, conversation)
    }

    /// With a slot blob the segment equal to its percent-encoded value wins; without one a single segment is used and
    /// several need the user's choice.
    static func chooseAccount(segments: Set<String>, slot: String?, chosen: String?) throws -> String {
        if let chosen {
            guard segments.contains(chosen) else { throw GrokCacheError.accountMismatch }
            return chosen
        }
        guard !segments.isEmpty else { throw GrokCacheError.noRoster }
        if let slot {
            guard let match = encodings(of: slot).first(where: segments.contains) else { throw GrokCacheError.accountMismatch }
            return match
        }
        guard segments.count == 1, let only = segments.first else { throw GrokCacheError.needsAccountChoice(accounts: segments.count) }
        return only
    }

    /// `encodeURIComponent` (what an Electron app writes), the stricter alphanumerics-only form, and the raw value.
    static func encodings(of slot: String) -> [String] {
        var component = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        component.insert(charactersIn: "-_.!~*'()")
        let ascii = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        let encoded = [component, ascii].map { slot.addingPercentEncoding(withAllowedCharacters: $0) }
        return encoded.compactMap { $0 } + [slot]
    }

    // MARK: Files

    private func listFolder() throws -> [String] {
        let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { throw GrokCacheError.symlinked }
        do { return try FileManager.default.contentsOfDirectory(atPath: folder.path) }
        catch { throw Self.mapped(error, missing: .notFound) }
    }

    private func isLink(_ name: String) -> Bool {
        let values = try? folder.appending(path: name).resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        return values?.isSymbolicLink != false || values?.isRegularFile != true
    }

    private func slot(from root: JSONValue) -> String? {
        root["value"]?.stringValue ?? root["value"]?["value"]?.stringValue
    }

    /// Reads one blob as a JSON object, retrying once on a JSON error (Grok Bot may be mid-write).
    private func blob(_ name: String) throws -> JSONValue {
        let url = folder.appending(path: name)
        for attempt in 0..<2 {
            let data: Data
            do { data = try readFile(url) } catch { throw Self.mapped(error, missing: .blobUnreadable) }
            guard data.count <= Self.maximumBlobBytes else { throw GrokCacheError.blobUnreadable }
            if let value = try? GrokJSON.parse(data), value.objectValue != nil { return value }
            if attempt == 1 { break }
        }
        throw GrokCacheError.blobUnreadable
    }

    /// EPERM/EACCES → "cannot read Grok Bot's folder"; a missing item → `missing`.
    static func mapped(_ error: Error, missing: GrokCacheError) -> GrokCacheError {
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            ?? (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        if posix == Int(EPERM) || posix == Int(EACCES) || nsError.code == NSFileReadNoPermissionError { return .folderUnreadable }
        if posix == Int(ENOENT) || nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError { return missing }
        return .blobUnreadable
    }
}
