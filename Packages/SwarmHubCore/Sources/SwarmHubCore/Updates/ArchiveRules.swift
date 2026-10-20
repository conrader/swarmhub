import Foundation

/// In-memory, uncompressed POSIX ustar validation only. Never writes files or follows links.
public enum ArchiveRules {
    public struct Invalid: Error, Equatable, Sendable {
        public let reason: String
    }
    public struct Entry: Sendable {
        public fileprivate(set) var name: String
        public let mode: Int
        public let size: Int
        public var isDirectory: Bool { flag == 53 }
        fileprivate let flag: UInt8
        /// Offset of the entry's body in the archive.
        fileprivate let offset: Int
    }
    public struct Inspection: Sendable {
        public let entries: [Entry]
        public let needsCode: Bool
    }

    public static func safeRelative(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || [45, 46, 95].contains($0)
            }
        }
    }

    public static func check(_ data: Data, kind: String, limits: UpdateLimits = .init()) throws -> Inspection {
        guard limits.valid else { throw UpdateInputError.invalidCallerInput }
        var entries = try read(data)
        try checkRule(entries.count <= limits.maxEntries, "archive_oversize")
        var paths: Set<String> = [], directories: Set<String> = []
        var total = 0
        var needsCode = false
        let extensions: [String: Set<String>] = ["skill": [".md"], "config": [".json", ".md", ".txt"],
                                                "ui": [".json"]]
        for index in entries.indices {
            let flag = entries[index].flag
            try checkRule(![49, 50].contains(flag), "archive_link")
            try checkRule(![51, 52, 54].contains(flag), "archive_special_file")
            try checkRule([48, 53].contains(flag), "archive_unsupported_entry")
            if flag == 53 && entries[index].name.hasSuffix("/") { entries[index].name.removeLast() }
            let entry = entries[index]
            let name = entry.name
            try checkRule(name.utf8.count <= limits.maxPathBytes
                          && name.split(separator: "/", omittingEmptySubsequences: false).count <= limits.maxDepth
                          && safeRelative(name), "archive_unsafe_path")
            try checkRule(!paths.contains(name), "archive_duplicate_path")
            paths.insert(name)
            try checkRule(flag == 53 ? entry.mode == 0o755 : [0o644, 0o755].contains(entry.mode), "archive_bad_mode")
            if flag == 53 { directories.insert(name); continue }
            try checkRule(entry.size <= limits.maxFileSize, "archive_oversize")
            // Check the subtraction before adding, so even adversarial caller limits cannot overflow.
            try checkRule(entry.size <= limits.maxTotalSize - total, "archive_oversize")
            total += entry.size
            if entry.mode == 0o755 || !(extensions[kind] ?? []).contains(fileExtension(name)) { needsCode = true }
        }
        let files = paths.subtracting(directories)
        for name in paths {
            var parts = name.split(separator: "/").map(String.init)
            parts.removeLast()
            while !parts.isEmpty {
                try checkRule(!files.contains(parts.joined(separator: "/")), "archive_path_conflict")
                parts.removeLast()
            }
        }
        return Inspection(entries: entries, needsCode: needsCode)
    }

    /// Regular-file contents by path, after every rule of `check` has passed. Still in memory only: nothing is
    /// written, and the caller decides which paths it interprets (P6a reads root-level config documents).
    public static func files(_ data: Data, kind: String, limits: UpdateLimits = .init()) throws -> [String: Data] {
        let inspection = try check(data, kind: kind, limits: limits)
        var result: [String: Data] = [:]
        for entry in inspection.entries where !entry.isDirectory {
            let start = data.startIndex + entry.offset
            result[entry.name] = Data(data[start..<start + entry.size])
        }
        return result
    }

    private static func fileExtension(_ name: String) -> String {
        let base = name.split(separator: "/").last.map(String.init) ?? ""
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex,
              base.index(after: dot) != base.endIndex else { return "" }
        return String(base[dot...])
    }

    private static func checkRule(_ condition: Bool, _ reason: String) throws {
        if !condition { throw Invalid(reason: reason) }
    }

    private static func read(_ data: Data) throws -> [Entry] {
        let bytes = Array(data)
        var entries: [Entry] = []
        var offset = 0
        while true {
            try checkRule(offset <= bytes.count && bytes.count - offset >= 512, "archive_malformed")
            let header = Array(bytes[offset..<offset + 512])
            if header.allSatisfy({ $0 == 0 }) {
                try checkRule(bytes.count - offset >= 1024 && bytes[(offset + 512)...].allSatisfy { $0 == 0 },
                              "archive_malformed")
                return entries
            }
            try checkRule(Array(header[257..<265]) == Array("ustar\0".utf8) + Array("00".utf8), "archive_malformed")
            let stored = try number(header, start: 148, length: 8)
            let sum = header[..<148].reduce(0) { $0 + Int($1) }
                + 8 * 32 + header[156...].reduce(0) { $0 + Int($1) }
            try checkRule(stored == sum, "archive_malformed")
            let name = field(header, start: 0, length: 100)
            let prefix = field(header, start: 345, length: 155)
            let full = prefix.isEmpty ? name : prefix + [47] + name
            guard let path = String(bytes: full, encoding: .utf8) else { throw Invalid(reason: "archive_unsafe_path") }
            let flag = header[156] == 0 ? 48 : header[156]
            let size = try number(header, start: 124, length: 12)
            let mode = try number(header, start: 100, length: 8)
            offset += 512
            let body = (49...54).contains(flag) ? 0 : size
            try checkRule(body <= bytes.count - offset, "archive_malformed")
            entries.append(Entry(name: path, mode: mode, size: size, flag: flag, offset: offset))
            offset += (body + 511) / 512 * 512
        }
    }

    private static func field(_ header: [UInt8], start: Int, length: Int) -> [UInt8] {
        Array(header[start..<start + length].prefix { $0 != 0 })
    }

    private static func number(_ header: [UInt8], start: Int, length: Int) throws -> Int {
        let bytes = field(header, start: start, length: length)
        let text = bytes.drop(while: { $0 == 32 }).reversed().drop(while: { $0 == 32 }).reversed()
        try checkRule(!text.isEmpty && text.allSatisfy { (48...55).contains($0) }, "archive_malformed")
        // The largest wire field is 12 octal bytes (< 2^36), representable on supported 64-bit platforms.
        return text.reduce(0) { $0 * 8 + Int($1 - 48) }
    }
}
