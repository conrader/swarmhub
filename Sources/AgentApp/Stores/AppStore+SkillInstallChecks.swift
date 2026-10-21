import Foundation

/// A SwarmHub skill install that did not land, kept per bot and skill for the version and variant it asked for. 0.6.0:
/// Hermes's guard refused a heredoc, nothing was recorded, the banner came back and every press re-sent all the skills.
/// A newer bundled version or another variant starts clean.
struct SkillInstallFailure: Codable, Equatable {
    var version: String
    var variant: String?
    var count: Int
    var lastAt: Date
    var reason: String

    /// No retry before this: 15 minutes after the first failure, doubling with each one, at most a day.
    var retryAt: Date { lastAt.addingTimeInterval(min(900 * pow(2, Double(max(count, 1) - 1)), 86_400)) }
}

/// One skill an install turn asked the manager to write, checked against that turn's `skills_installed` block.
struct SkillInstallCheck: Equatable {
    let botID: UUID; let profile: String; let skill: String; let version: SkillVersion; let variant: String?
}

extension AppStore {
    /// The failure recorded for this skill's bundled version and this bot's variant; nil when there is none. On a staged
    /// connection the signed bundle decides the version and only its send verifies it, so any version's failure counts here;
    /// the send itself holds back by the bundle's version (`stagedSkillBackingOff`).
    func skillInstallFailure(_ skill: BundledSkill, for bot: Bot) -> SkillInstallFailure? {
        guard let failure = bot.skillInstallFailures[skill.name],
              failure.variant == SkillLibrary.variant(of: skill, codingOrder: codingOrder(for: bot)),
              failure.version == skill.version.description || usesStagedSkills(on: connection(of: bot)) else { return nil }
        return failure
    }

    /// True while a failed install of this version waits out its backoff: it is neither sent again nor offered.
    func skillInstallBackingOff(_ skill: BundledSkill, for bot: Bot) -> Bool {
        skillInstallFailure(skill, for: bot).map { now() < $0.retryAt } ?? false
    }

    /// When the backoff of a failed install of one of `skills` ends, so an idle view redraws then and offers Retry again.
    func skillRetryDates(_ skills: [BundledSkill], for bot: Bot) -> [Date] {
        skills.compactMap { skillInstallFailure($0, for: bot)?.retryAt }.filter { $0 > now() }.sorted()
    }

    /// The skills an install press may send for `bot`: those that need it and are not backing off. A skill whose
    /// installed version and variant already match is never sent again, nor (dev mode) one the bot modified locally.
    func skillsToInstall(for bot: Bot, among skills: [BundledSkill]? = nil) -> [BundledSkill] {
        (skills ?? self.skills(for: bot)).filter {
            skillState($0, for: bot).needsAction && !skillInstallBackingOff($0, for: bot) && !isModifiedLocally($0, for: bot)
        }
    }

    /// Remembers what the install turn about to be sent asks for.
    func noteSkillInstallChecks(_ wanted: [(bot: Bot, skills: [BundledSkill])], manager: Bot) {
        peerEnableCalls[manager.id] = nil
        pendingSkillChecks[manager.id] = wanted.flatMap { bot, skills in
            skills.map { SkillInstallCheck(botID: bot.id, profile: profile(of: bot), skill: $0.name, version: $0.version,
                                           variant: SkillLibrary.variant(of: $0, codingOrder: codingOrder(for: bot))) }
        }
    }

    /// The manager's install turn ended. Each skill its block reports at the version and variant asked for clears its
    /// failure; every other one is a failure with the reason (the turn's error, or the start of the reply), and the
    /// error is shown once. Dev mode: a skill the box kept is modified locally, never a failure (so it never backs off);
    /// one whose guard failed is a failure whatever the block says.
    func finishSkillInstallChecks(manager: Bot, reply: ChatMessage, end: TurnEnd) {
        let outcomes = skillDevOutcomes.removeValue(forKey: manager.id) ?? [:]
        guard let checks = pendingSkillChecks.removeValue(forKey: manager.id), !checks.isEmpty else { return }
        let receipts = peerEnableCalls.removeValue(forKey: manager.id)?.receipts ?? [:]
        let batch = allBotsSkillBatch.removeValue(forKey: manager.id) ?? []
        if SkillInstallPayloadError.isPayloadError(end) {
            // 0.6.4: a batch the provider refused goes again one bot per turn, as before batching; nothing is recorded yet.
            if batch.count > 1, let queue = allBotsSkillQueue[manager.id] {
                allBotsSkillSolo[manager.id, default: []].formUnion(batch.map(\.bot.id))
                allBotsSkillQueue[manager.id] = batch + queue
                return
            }
            let reason = "Client-side install payload error: \(Self.skillInstallFailureReason(end, reply: reply)). Install backoff unchanged."
            for id in Set(checks.map(\.botID)) {
                guard let bot = bots.first(where: { $0.id == id }) else { continue }
                recordSkillInstallResult(.init(status: .clientPayloadError, detail: reason), bot: bot, manager: manager)
            }
            errorMessage = reason
            return
        }
        var reported: [String: [SwarmhubOp.InstalledSkill]] = [:]
        if case .completed = end {
            // Dev mode: rows the box kept or failed to write are not installs (recordInstalled would clear "modified locally").
            for case .skillsInstalled(let profile, let rows) in SwarmhubBlock.ops(in: reply.content) ?? [] {
                reported[profile, default: []] += rows.filter { outcomes["\(profile)/\($0.name)"] == nil }
            }
        }
        let reason = Self.skillInstallFailureReason(end, reply: reply)
        var failed: [String] = []
        var failedBots: Set<UUID> = []
        var peerBlocked = false
        let reportedPeerBlock = PeerPluginEnablement.reportedBlock(SwarmhubBlock.visibleText(reply.finalText))
        for check in checks {
            guard let bot = bots.first(where: { $0.id == check.botID }) else { continue }
            let outcome = outcomes["\(check.profile)/\(check.skill)"]
            if outcome == .kept { bot.skillInstallFailures[check.skill] = nil; bot.skillsModifiedLocally.insert(check.skill); continue }
            let landed = outcome == nil && reported[check.profile]?.contains {
                $0.name == check.skill && (SkillVersion($0.version).map { $0 >= check.version } ?? false) && (check.variant == nil || $0.variant == check.variant)
            } ?? false
            if landed {
                recordInstalled(reported[check.profile] ?? [], profile: check.profile, manager: manager)
                bot.skillInstallFailures[check.skill] = nil; continue
            }
            // PM admission is separate from writing the messaging skill/plugin. A blocked enable never backs off
            // skill installation, including older servers whose reply omitted the skills_installed block.
            let enableIssue = (receipts[check.profile].map { !$0.verified } ?? false) || (!bot.skillDevMode && reportedPeerBlock)
            if outcome == nil && enableIssue && (check.skill == "swarmhub-messages" || reported[check.profile] == nil) { continue }
            noteSkillInstallFailure(check.skill, version: check.version.description, variant: check.variant, reason: reason, on: bot)
            failed.append("\(check.skill) for \(bot.name)")
            failedBots.insert(bot.id)
        }
        for id in Set(checks.map(\.botID)) {
            guard let bot = bots.first(where: { $0.id == id }) else { continue }
            let result: SkillInstallResult
            if failedBots.contains(id) {
                result = .init(status: .failed, detail: "Skills not fully installed: \(reason)")
            } else if checks.contains(where: { $0.botID == id && $0.skill == "swarmhub-messages" }) {
                if let peer = receipts[profile(of: bot)] { result = peer.result }
                else if !bot.skillDevMode && reportedPeerBlock { result = .init(status: .peerEnableBlocked, detail: PeerPluginEnablement.blockedDetail) }
                else { result = .init(status: .peerEnableUnverified, detail: "Skills installed; peer-plugin enablement unverified. Held delivery is not confirmed; verify with hermes -p \(profile(of: bot)) plugins list before requesting a gateway reload.") }
            } else { result = .init(status: .installed, detail: "Skills installed.") }
            recordSkillInstallResult(result, bot: bot, manager: manager)
            if result.status == .peerEnableBlocked, receipts[profile(of: bot)]?.skipped != true { peerBlocked = true }
        }
        // Only an attempt that ran counts: a skipped enable never extends the window, a verified one ends it.
        if receipts.values.contains(where: \.verified) { notePeerEnableBlocked(false, on: connection(of: manager)) }
        else if peerBlocked { notePeerEnableBlocked(true, on: connection(of: manager)) }
        if !failed.isEmpty { errorMessage = "SwarmHub’s instructions were not installed (\(failed.joined(separator: ", "))): \(reason)" }
        objectWillChange.send(); save()
    }

    /// Counts one more failure of this version and variant (a different one starts at one) and logs it.
    func noteSkillInstallFailure(_ skill: String, version: String, variant: String?, reason: String, on bot: Bot) {
        let previous = bot.skillInstallFailures[skill].flatMap { $0.version == version && $0.variant == variant ? $0.count : nil } ?? 0
        bot.skillInstallFailures[skill] = SkillInstallFailure(version: version, variant: variant, count: previous + 1, lastAt: now(), reason: reason)
        SwarmhubBlock.log.error("Skill install failed: \(skill, privacy: .public) \(version, privacy: .public) on \(bot.hermesProfile ?? "default", privacy: .public) (\(previous + 1)x)")
        scheduleSkillRetryRedraw()
    }

    /// The earliest retry time after `date` of a failed install a bot still has (its bundled version and variant).
    func nextSkillRetry(after date: Date) -> Date? {
        bots.flatMap { bot in skills(for: bot).compactMap { skillInstallFailure($0, for: bot)?.retryAt } }.filter { $0 > date }.min()
    }

    /// Views read the backoff only when they draw, so nothing would bring Retry back when it ends: one task sleeps until
    /// the next retry time (plus a second) and redraws, then waits for the one after. It only redraws; it never installs.
    func scheduleSkillRetryRedraw(after floor: Date = .distantPast) {
        skillRetryRedraw?.cancel(); skillRetryRedraw = nil
        guard let next = nextSkillRetry(after: max(now(), floor)) else { return }
        let wait = Duration.seconds(max(next.timeIntervalSince(now()), 0) + 1), sleep = skillRetrySleep
        skillRetryRedraw = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.skillRetryRedraw = nil
            self.objectWillChange.send(); self.scheduleSkillRetryRedraw(after: next)
        }
    }

    /// A staged install of `name` failed at the version the signed bundle about to be sent carries, for this bot's variant,
    /// and still waits out its backoff.
    func stagedSkillBackingOff(_ name: String, version: String?, bot: Bot) -> Bool {
        guard let failure = bot.skillInstallFailures[name], failure.version == (version ?? ""),
              failure.variant == stagedVariant(name, for: bot) else { return false }
        return now() < failure.retryAt
    }

    /// The staged install turn ended: each requested skill the updater's accepted status advertises at the bundle's version
    /// (and, for the coding skill, the profile's coding order) clears its failure; every other one is a failure of that
    /// signed version with `reason`. Versions are the bundle's, never this build's fallback copy. Dev mode: a skill the
    /// updater kept as modified locally clears its failure instead, so it never holds back the connection's installs.
    func noteStagedSkillResults(_ package: StagedInstall.Package, status: BoxUpdaterStatus?, reason: String, manager: Bot) {
        for profile in package.profiles {
            guard let bot = boundBot(profile.name, manager: manager) else { continue }
            var failed = false
            for name in profile.skills {
                if status.map({ Self.stagedSkillLanded(name, profile: profile, package: package, status: $0) ||
                                Self.stagedSkillKept(name, profile: profile, status: $0) }) ?? false {
                    bot.skillInstallFailures[name] = nil; continue
                }
                if name == "swarmhub-messages", PeerPluginEnablement.reportedBlock(reason) { continue }
                noteSkillInstallFailure(name, version: package.versions[name] ?? "", variant: stagedVariant(name, for: bot), reason: reason, on: bot)
                failed = true
            }
            let result: SkillInstallResult
            if profile.skills.contains("swarmhub-messages"), PeerPluginEnablement.reportedBlock(reason) {
                result = .init(status: .peerEnableBlocked, detail: PeerPluginEnablement.blockedDetail)
            } else if failed { result = .init(status: .failed, detail: reason) }
            else { result = .init(status: .installed, detail: "Signed skills installed." + (status?.reload_pending == true ? " Gateway reload pending." : "")) }
            recordSkillInstallResult(result, bot: bot, manager: manager)
        }
        objectWillChange.send(); save()
    }

    /// The updater advertises `name` in `profile` at the bundle's version (the coding skill also in the profile's order).
    static func stagedSkillLanded(_ name: String, profile: StagedInstall.Profile, package: StagedInstall.Package, status: BoxUpdaterStatus) -> Bool {
        guard let live = status.profiles[profile.name], let version = package.versions[name] else { return false }
        return (live.advertised[name] ?? nil) == version && (name != "swarmhub-coding" || live.variants?[name] == profile.coding_order)
    }

    /// The updater kept `name` in this dev-mode profile because the bot modified it there.
    static func stagedSkillKept(_ name: String, profile: StagedInstall.Profile, status: BoxUpdaterStatus) -> Bool {
        profile.dev_mode == true && status.profiles[profile.name]?.modified?.contains(name) == true
    }

    private func stagedVariant(_ name: String, for bot: Bot) -> String? {
        skillLibrary.first { $0.name == name }.flatMap { SkillLibrary.variant(of: $0, codingOrder: codingOrder(for: bot)) }
    }

    /// Why the turn did not confirm the install, in one line: the turn's own failure, else the start of the reply.
    static func skillInstallFailureReason(_ end: TurnEnd, reply: ChatMessage) -> String {
        switch end {
        case .stoppedByUser: return "The install turn was stopped."
        case .failedByBox(let why): return "The install turn failed: \(why)"
        case .error(let error): return "The install turn failed: \(error.localizedDescription)"
        case .endedWithoutTerminal: return "The install turn ended before it finished."
        case .completed:
            let said = SwarmhubBlock.visibleText(reply.finalText).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let line = said.count > 160 ? String(said.prefix(159)) + "…" : said
            return line.isEmpty ? "The manager did not confirm the install." : "The manager did not confirm the install: “\(line)”"
        }
    }

    /// Plain words for a failure: what failed, how often, why, and when it may be retried.
    func skillFailureText(_ failure: SkillInstallFailure, skill: BundledSkill) -> String {
        let times = failure.count > 1 ? " \(failure.count) times" : ""
        let retry = now() < failure.retryAt ? " Retry after \(failure.retryAt.formatted(date: .omitted, time: .shortened))." : ""
        return "Installing \(skill.name) v\(failure.version) failed\(times). \(failure.reason)\(retry)"
    }
}
