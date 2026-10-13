import Foundation

/// Names, slugs and timestamps exactly as `scripts/export-grokbot.py` writes them.
enum GrokNaming {
    /// `slugify`: lowercased runs of `[a-z0-9]` joined by `-`, or `bot`.
    static func slugify(_ name: String) -> String {
        var runs: [String] = []
        var current = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.isEmpty ? "bot" : runs.joined(separator: "-")
    }

    /// `profile_slug`: trimmed, lowercased, each space a `-` (so `Finance  Controller` keeps both dashes).
    static func profileSlug(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// The Hermes profile Torvli binds a Grok bot to: `grok-` + `profile_slug(name)` when that is a valid profile name,
    /// else `grok-` + `slugify(name)` (an empty name gives `grok-bot`).
    static func profile(forName name: String) -> String {
        let slug = profileSlug(name)
        if !slug.isEmpty, HermesKeyPaste.isValidProfileName("grok-" + slug) { return "grok-" + slug }
        return "grok-" + slugify(name)
    }

    /// `iso(ms)`: `YYYY-MM-DDTHH:MM:SS.mmmZ` in UTC, by integer arithmetic (no floating point).
    static func iso(_ ms: Int64) -> String {
        let seconds = floorDivide(ms, 1000), millis = ms - seconds * 1000
        let days = floorDivide(seconds, 86_400), secondOfDay = seconds - days * 86_400
        let (year, month, day) = civil(fromDays: days)
        return String(format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ", year, month, day,
                      secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60, millis)
    }

    private static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    /// Days since 1970-01-01 → proleptic Gregorian (year, month, day) (H. Hinnant's `civil_from_days`).
    private static func civil(fromDays days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = floorDivide(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
