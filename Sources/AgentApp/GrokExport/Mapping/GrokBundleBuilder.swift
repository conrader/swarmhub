import Foundation

/// Roster rows + transcripts → one `GrokBundleV1` per conversation, in roster order (port of `export` and
/// `build_bundle`, in memory: nothing is written and the roster id never enters a path).
enum GrokBundleBuilder {
    struct Warning: Sendable, Equatable {
        /// The roster id of the bot that was left without a profile.
        var sourceID: String
        var name: String
        /// The profile another bot already took.
        var duplicateProfile: String
    }

    struct Result: Sendable {
        var bundles: [GrokBundleV1]
        var warnings: [Warning]
    }

    static let cacheLimitation =
        "The Grok Bot app cache holds only the latest entries of each conversation; older history stays on Grok's servers."
    static let cardsLimitation = "Interactive cards (secret requests, connectors, forms, approvals) were not exported."
    static let eventsLimitation = "Automation lifecycle events were not exported."

    static func build(_ cache: GrokCache) -> Result { build(roster: cache.roster, transcripts: cache.transcripts) }

    /// `gaps`: per conversation, the server-history seq gaps once P10b fetched it; nil = cache only.
    static func build(roster: [[String: JSONValue]], transcripts: [String: [JSONValue]], gaps: [String: [[Int64]]]? = nil) -> Result {
        let rows = roster.filter { $0["id"]?.stringValue != nil }
        var names: [String: String] = [:]
        for row in rows { names[row["id"]!.stringValue!] = nonEmpty(row["name"]) ?? "Grok bot" }
        // Profiles in roster order; a later bot whose profile is taken gets none (history-only) and a warning.
        var profiles: [String: String] = [:], slugs: [String: String] = [:], taken: Set<String> = [], warnings: [Warning] = []
        for row in rows where !(row["isGroup"]?.isTruthy ?? false) {
            let id = row["id"]!.stringValue!, raw = row["name"]?.stringValue ?? ""
            slugs[id] = GrokNaming.profileSlug(raw)
            let profile = GrokNaming.profile(forName: raw)
            if taken.insert(profile).inserted { profiles[id] = profile } else {
                warnings.append(.init(sourceID: id, name: names[id] ?? "Grok bot", duplicateProfile: profile))
            }
        }
        let bundles = rows.map { row in
            let id = row["id"]!.stringValue!
            return bundle(row, entries: transcripts[id] ?? [], names: names, profiles: profiles, slug: slugs[id], gaps: gaps?[id])
        }
        return Result(bundles: bundles, warnings: warnings)
    }

    private static func bundle(_ row: [String: JSONValue], entries: [JSONValue], names: [String: String], profiles: [String: String],
                               slug: String?, gaps: [[Int64]]?) -> GrokBundleV1 {
        var redact = GrokRedactor()
        var stats = GrokBundleV1.Statistics()
        stats.transcriptRows = entries.count
        let id = row["id"]!.stringValue!
        let name = redact(nonEmpty(row["name"]) ?? "Grok bot")
        let isGroup = row["isGroup"]?.isTruthy ?? false
        let (messages, events) = GrokEntryMapper(names: names, botName: name).map(entries, redact: &redact, stats: &stats)
        stats.messages = messages.count; stats.events = events.count
        stats.hiddenMessages = messages.filter(\.hidden).count
        let description = redact(row["description"]?.stringValue ?? "")
        let members = (row["memberIds"]?.arrayValue ?? []).compactMap(\.stringValue).map { member in
            GrokBundleV1.Member(sourceID: member, name: redact(names[member] ?? "Unknown bot"), profile: profiles[member])
        }
        var limitations = gaps.map(gapLimitations) ?? [cacheLimitation]
        if stats.cardsDropped > 0 { limitations.append(cardsLimitation) }
        if stats.eventsDropped > 0 { limitations.append(eventsLimitation) }
        let title = redact(row["title"]?.stringValue ?? "")
        return GrokBundleV1(
            sourceID: id, slug: slug.flatMap { $0.isEmpty ? nil : $0 } ?? GrokNaming.slugify(name), name: name,
            description: description, title: title,
            avatarShape: avatarValue(row["avatarShape"]), avatarColour: avatarValue(row["avatarColor"]),
            profile: isGroup ? nil : profiles[id], isGroup: isGroup, members: members, messages: messages, events: events,
            source: .init(createdAtMs: row["createdAt"]?.intValue, harness: row["harness"]?.stringValue,
                          notifyOnAgentUpdates: row["notifyOnUpdatesEnabled"]?.boolValue,
                          hiddenFromSidebar: row["isHiddenFromSidebar"]?.isTruthy ?? false),
            limitations: limitations, statistics: stats, redactions: redact.counts)
    }

    /// The script's server-history limitation, verbatim: at most 20 ranges named, then a count of the rest.
    static func gapLimitations(_ gaps: [[Int64]]) -> [String] {
        guard !gaps.isEmpty else { return [] }
        let named = gaps.prefix(20).map { gap in gap.first == gap.last ? "\(gap.first ?? 0)" : "\(gap.first ?? 0)-\(gap.last ?? 0)" }
        let more = gaps.count > 20 ? " (and \(gaps.count - 20) more gaps)" : ""
        return ["Grok's server returned no entries for seq \(named.joined(separator: ", "))." + more]
    }

    /// `avatar_value`: a trimmed non-empty string, else nil.
    private static func avatarValue(_ value: JSONValue?) -> String? {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}
