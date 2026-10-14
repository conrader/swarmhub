import Foundation
import Testing
@testable import AgentApp

/// P32 7: the visible name is `AppConstants.name`; "AgentApp" is only the internal codename.
///
/// What the guard scans: every string literal (one-line `"…"` and multi-line `"""…"""`) in `Sources/AgentApp/**/*.swift`
/// except `Sources/AgentApp/Vendor/`; comments are skipped. It flags "AgentApp" used as a word in prose. Not flagged:
/// the codename inside identifiers, paths, bundle names and notification names (`AgentApp/store.json`,
/// `AgentApp_AgentApp.bundle`, `AgentApp.toggleInfo`, `AgentAppTests-…`, `AgentApp-setup-preview-…`), a literal that is
/// exactly `"AgentApp"` (the data folder), and the command-line usage lines (`Usage: AgentApp --…`), which name the
/// executable. Type names are not literals, and tests are not scanned.
enum VisibleNameGuard {
    static let word = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_./-])AgentApp(?![A-Za-z0-9_./-])"#)
    static let literal = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)

    static let block = String(repeating: "\"", count: 3)

    static func literals(in source: String) -> [(line: Int, text: String)] {
        var found: [(Int, String)] = []; var inBlock = false
        for (index, raw) in source.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains(block) {
                let parts = raw.components(separatedBy: block)
                // An odd number of delimiters on the line opens or closes a block.
                if parts.count % 2 == 0 { inBlock.toggle(); if !inBlock { found.append((index + 1, parts.first ?? "")) } else { found.append((index + 1, parts.last ?? "")) } }
                continue
            }
            if inBlock { found.append((index + 1, raw)); continue }
            if line.hasPrefix("//") { continue }
            let range = NSRange(raw.startIndex..., in: raw)
            for match in literal.matches(in: raw, range: range) { found.append((index + 1, (raw as NSString).substring(with: match.range(at: 1)))) }
        }
        return found
    }

    static func isVisibleUse(_ text: String) -> Bool {
        guard text != "AgentApp", !text.hasPrefix("Usage: AgentApp ") else { return false }
        return word.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

@Test func noUserVisibleStringSaysAgentApp() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appending(path: "Sources/AgentApp")
    let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && !$0.path.contains("/Sources/AgentApp/Vendor/") }
    #expect(files.count > 100, "the guard sees the sources")
    var offenders: [String] = []
    for file in files {
        for (line, text) in VisibleNameGuard.literals(in: try String(contentsOf: file, encoding: .utf8)) where VisibleNameGuard.isVisibleUse(text) {
            offenders.append("\(file.lastPathComponent):\(line): \(text)")
        }
    }
    #expect(offenders.isEmpty, "use AppConstants.name: \(offenders.joined(separator: "\n"))")
}

@Test func visibleNameGuardTellsProseFromIdentifiers() {
    #expect(VisibleNameGuard.isVisibleUse("Used as AgentApp bot metadata."))
    #expect(VisibleNameGuard.isVisibleUse("Saved in AgentApp"))
    for name in ["AgentApp", "AgentApp/store.json", "AgentApp_AgentApp.bundle/x", "AgentApp.toggleInfo", "AgentAppTests-unguarded-1",
                     "AgentApp-setup-preview-1", "Usage: AgentApp --render-setup <dir>", "SwarmHub bot metadata"] {
        #expect(!VisibleNameGuard.isVisibleUse(name), "\(name)")
    }
    let source = "let a = \"in AgentApp\"\n// \"AgentApp says\"\nlet b = \"\"\"\nhello AgentApp\n\"\"\"\n"
    #expect(VisibleNameGuard.literals(in: source).filter { VisibleNameGuard.isVisibleUse($0.text) }.map(\.line) == [1, 4])
}
