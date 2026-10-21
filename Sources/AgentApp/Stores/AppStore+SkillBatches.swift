import Foundation

/// 0.6.4 speed: a legacy all-bots install took ~70-100 s per bot, one bot per manager turn (16 bots: 21 min on 21 Oct).
/// Each turn paid four or five model round trips plus a peer-plugin enable that Hermes PM refused on every profile. Now
/// up to `allBotsBatchLimit` (8) bots share one turn under the payload budget, a skill another profile on the box
/// already holds is copied from it (`SkillSync`), and one peer call covers the batch, skipping enable once PM blocks it.
/// The manager has one turn slot, so a batch is the bounded parallelism; bots never run as concurrent manager turns.
extension AppStore {
    /// Leaves room under the 512 KiB budget for the policy and persona the backend composes around the instructions.
    static let allBotsPlanningBudget = SkillInstallPayloadError.instructionsByteBudget - 64 * 1024
    /// How long a PM-blocked enable on a box keeps all-bots batches from retrying it (a single bot's Install always tries).
    static let peerBlockWindow: TimeInterval = 12 * 3600

    private static func peerBlockKey(_ connection: String) -> String { "skills.peerEnableBlocked." + connection }

    func peerEnableKnownBlocked(on connection: String) -> Bool {
        let at = defaults.double(forKey: Self.peerBlockKey(connection))
        return at > 0 && now().timeIntervalSince1970 - at < Self.peerBlockWindow
    }

    func notePeerEnableBlocked(_ blocked: Bool, on connection: String) {
        if blocked { defaults.set(now().timeIntervalSince1970, forKey: Self.peerBlockKey(connection)) }
        else { defaults.removeObject(forKey: Self.peerBlockKey(connection)) }
    }

    /// Where each skill `gap` installs can be copied from: a bot on the same box recorded at this version and variant (the
    /// manager first), else an earlier bot of this batch that writes it. None in dev mode, nor for a skill whose last
    /// install failed: that retry writes every file out, so a bad source cannot keep a bot failing.
    func skillSources(for gap: SkillGap, in batch: [SkillGap]) -> [String: SkillSource] {
        guard !gap.bot.skillDevMode else { return [:] }
        let target = connection(of: gap.bot), own = profile(of: gap.bot)
        var sources: [String: SkillSource] = [:]
        for skill in gap.installable where gap.bot.skillInstallFailures[skill.name] == nil {
            let holders = bots.filter { bot in
                bot.id != gap.bot.id && bot.backend == .hermes && !bot.isReadOnlyArchive && !bot.skillDevMode && profile(of: bot) != own &&
                    connection(of: bot) == target && HermesKeyPaste.isValidProfileName(profile(of: bot)) &&
                    skills(for: bot).contains { $0.name == skill.name } && !skillState(skill, for: bot).needsAction
            }
            let earlier = batch.prefix { $0.bot.id != gap.bot.id }.map(\.bot).first { bot in
                !bot.skillDevMode && profile(of: bot) != own && batch.first { $0.bot.id == bot.id }?.installable.contains { $0.name == skill.name } == true
            }
            if let source = holders.first(where: { isManager($0) }) ?? holders.first ?? earlier {
                sources[skill.name] = SkillSource(profile: profile(of: source), codingOrder: codingOrder(for: source))
            }
        }
        return sources
    }

    /// The next all-bots turn from the front of `queue`. A dev-mode bot, or one whose batch the provider refused, goes
    /// alone; otherwise the bots after it join while the batch stays within the bot cap and the planning budget. Throws
    /// when the first bot's files cannot be rendered (it is reported and the batch moves on).
    func nextAllBotsBatch(_ queue: [SkillGap], manager: Bot) throws -> (gaps: [SkillGap], instructions: String) {
        let solo = allBotsSkillSolo[manager.id] ?? []
        func alone(_ gap: SkillGap) -> Bool { gap.bot.skillDevMode || solo.contains(gap.bot.id) }
        guard let first = queue.first, let text = try allBotsSkillInstructions([first]) else {
            throw BackendError.unavailable("Could not render this bot's skill files or validate its profile.")
        }
        var batch = [first], instructions = text
        guard !alone(first) else { return (batch, instructions) }
        for gap in queue.dropFirst() {
            guard batch.count < allBotsBatchLimit, !alone(gap), let next = try? allBotsSkillInstructions(batch + [gap]),
                  Self.encodedInstructionsSize(next) <= Self.allBotsPlanningBudget else { break }
            batch.append(gap); instructions = next
        }
        return (batch, instructions)
    }

    static func encodedInstructionsSize(_ text: String) -> Int {
        (try? JSONSerialization.data(withJSONObject: ["instructions": text]).count) ?? .max
    }
}
