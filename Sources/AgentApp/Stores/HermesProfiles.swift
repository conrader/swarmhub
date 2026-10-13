import Foundation

enum HermesProfileNaming {
    /// `grok-jarvis` → "Jarvis", `finance-controller` → "Finance Controller".
    static func botName(forProfile profile: String) -> String {
        var slug = Substring(profile)
        if slug.lowercased().hasPrefix("grok-"), slug.count > 5 { slug = slug.dropFirst(5) }
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? profile : words.joined(separator: " ")
    }
}

struct HermesKeyPasteEntry: Equatable { let profile: String; let key: String }

enum HermesKeyPaste {
    struct Invalid: Equatable { let label: String; let reason: String }

    static func isValidProfileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Parses `profile=key` entries separated by newlines or commas. Only the first `=` splits, so
    /// keys may contain `=`. A later entry for the same profile wins. Invalid entries are reported by
    /// position only, so a mistyped key is never echoed back.
    static func parse(_ text: String) -> (entries: [HermesKeyPasteEntry], invalid: [Invalid]) {
        var entries: [HermesKeyPasteEntry] = []; var invalid: [Invalid] = []
        let pieces = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for (index, piece) in pieces.enumerated() {
            let label = "Entry \(index + 1)"
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { invalid.append(.init(label: label, reason: "Expected profile=key.")); continue }
            let profile = pair[0].trimmingCharacters(in: .whitespaces), key = pair[1].trimmingCharacters(in: .whitespaces)
            guard isValidProfileName(profile) else { invalid.append(.init(label: label, reason: "Invalid profile name (letters, digits, - and _ only).")); continue }
            guard profile != "default" else { invalid.append(.init(label: "default", reason: "Use the Default profile API key field.")); continue }
            guard !key.isEmpty else { invalid.append(.init(label: profile, reason: "Missing key.")); continue }
            entries.removeAll { $0.profile == profile }
            entries.append(.init(profile: profile, key: key))
        }
        return (entries, invalid)
    }
}

struct HermesBotAddResult: Identifiable, Equatable {
    enum Outcome: Equatable { case added(String), alreadyPresent, rejected(String) }
    var id: String { label }
    let label: String
    let outcome: Outcome
    var summary: String {
        switch outcome {
        case .added(let name): "added as \(name)"
        case .alreadyPresent: "already present"
        case .rejected(let reason): "rejected — \(reason)"
        }
    }
}
