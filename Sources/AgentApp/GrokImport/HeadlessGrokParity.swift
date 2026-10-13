import Foundation

/// `AgentApp --grok-parity <python export folder> [--cache <sand-client-persistence>]`: builds the bundles from the cache
/// in memory (default: Grok Bot's real cache, read-only) and compares each with the bundle `scripts/export-grokbot.py`
/// wrote for the same cache. Prints per bot id "equal" or the differing field names with counts; never any text.
enum GrokParity {
    struct Line: Equatable, Sendable {
        var sourceID: String
        /// Top-level key → number of differing elements (array items, object keys, or 1 for a scalar).
        var differences: [String: Int]
        var onlyIn: String?

        var rendered: String {
            if let onlyIn { return "\(sourceID): only in \(onlyIn)" }
            if differences.isEmpty { return "\(sourceID): equal" }
            return "\(sourceID): differs " + differences.keys.sorted().map { "\($0) (\(differences[$0]!))" }.joined(separator: ", ")
        }
    }

    static func defaultCacheFolder() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: GrokProtocol.dataFolderName).appending(path: GrokProtocol.cacheFolderName)
    }

    /// Compares natively built bundles with the export's `index.json` bundles, matched by `source_id`.
    static func compare(native: [GrokBundleV1], exportFolder: URL) throws -> [Line] {
        let index = try GrokJSON.parse(Data(contentsOf: exportFolder.appending(path: "index.json")))
        var exported: [String: JSONValue] = [:]
        for entry in index["bots"]?.arrayValue ?? [] {
            guard let id = entry["source_id"]?.stringValue, let path = entry["bundle"]?.stringValue,
                  !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw GrokBundleError.unreadable("index.json") }
            exported[id] = try GrokJSON.parse(Data(contentsOf: exportFolder.appending(path: path)))
        }
        var lines = native.map { bundle -> Line in
            guard let other = exported.removeValue(forKey: bundle.sourceID) else {
                return Line(sourceID: bundle.sourceID, differences: [:], onlyIn: "Torvli")
            }
            return Line(sourceID: bundle.sourceID, differences: differences(bundle.json, other), onlyIn: nil)
        }
        lines += exported.keys.sorted().map { Line(sourceID: $0, differences: [:], onlyIn: "the Python export") }
        return lines
    }

    static func differences(_ lhs: JSONValue, _ rhs: JSONValue) -> [String: Int] {
        let left = lhs.objectValue ?? [:], right = rhs.objectValue ?? [:]
        var result: [String: Int] = [:]
        for key in Set(left.keys).union(right.keys) where left[key] != right[key] {
            switch (left[key], right[key]) {
            case (.array(let a)?, .array(let b)?):
                result[key] = zip(a, b).filter { $0 != $1 }.count + abs(a.count - b.count)
            case (.object(let a)?, .object(let b)?):
                result[key] = Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
            default:
                result[key] = 1
            }
        }
        return result
    }

    static func run(arguments: [String], output: (String) -> Void) -> Int32 {
        guard let flag = arguments.firstIndex(of: "--grok-parity"), arguments.indices.contains(flag + 1) else {
            output("Usage: AgentApp --grok-parity <python export folder> [--cache <folder>]"); return 64
        }
        let exportFolder = URL(fileURLWithPath: (arguments[flag + 1] as NSString).expandingTildeInPath)
        let cacheFolder = arguments.firstIndex(of: "--cache").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? defaultCacheFolder()
        do {
            let built = GrokBundleBuilder.build(try GrokCacheReader(folder: cacheFolder).read())
            let lines = try compare(native: built.bundles, exportFolder: exportFolder)
            lines.forEach { output($0.rendered) }
            built.warnings.forEach { output("\($0.sourceID): no profile (\($0.duplicateProfile) is taken by an earlier bot)") }
            let equal = lines.filter { $0.onlyIn == nil && $0.differences.isEmpty }.count
            output("bots=\(lines.count) equal=\(equal) different=\(lines.count - equal)")
            return equal == lines.count ? 0 : 1
        } catch {
            output("Parity check failed: \(error.localizedDescription)")
            return 2
        }
    }
}
