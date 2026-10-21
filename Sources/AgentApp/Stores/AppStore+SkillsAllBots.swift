import Foundation

/// P42 7: every bot gets the messaging skill. Settings and the manager's banner offer "Install SwarmHub skills on all
/// bots": one confirmation, then bounded management turns in which the manager writes `swarmhub-messages` and
/// `swarmhub-feedback` into each profile on its connection that lacks them (or has an older version). Bots that have
/// it use bot-msg instead of `hermes -p … chat`.
extension AppStore {
    static let messagingSkills: Set<String> = ["swarmhub-messages", "swarmhub-feedback"]

    /// One bot on the manager's connection, the messaging skills it still needs, and those a press sends now.
    struct SkillGap: Identifiable, Equatable {
        let bot: Bot; let skills: [BundledSkill]
        /// `skills` without those whose failed install waits out its backoff (still missing, never counted as done).
        let installable: [BundledSkill]
        var id: UUID { bot.id }
        static func == (a: SkillGap, b: SkillGap) -> Bool {
            a.bot.id == b.bot.id && a.skills.map(\.name) == b.skills.map(\.name) && a.installable.map(\.name) == b.installable.map(\.name)
        }
    }

    /// The messaging skills `bot` lacks or has older than this build ships, including one whose install failed; not one
    /// it modified locally in skill dev mode (that copy is the bot's own until Reset to bundled).
    func missingMessagingSkills(for bot: Bot) -> [BundledSkill] {
        skills(for: bot).filter { Self.messagingSkills.contains($0.name) && skillState($0, for: bot).needsAction && !isModifiedLocally($0, for: bot) }
    }

    /// Every Hermes bot on `manager`'s connection (the manager too) that needs one of them, in sidebar order. A bot whose
    /// install failed stays listed while it backs off; it only has nothing to send yet.
    func messagingSkillGaps(manager: Bot) -> [SkillGap] {
        guard isManager(manager), manager.backend == .hermes else { return [] }
        let target = connection(of: manager)
        return bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && connection(of: $0) == target }.compactMap { bot in
            let missing = missingMessagingSkills(for: bot)
            return missing.isEmpty ? nil : SkillGap(bot: bot, skills: missing, installable: skillsToInstall(for: bot, among: missing))
        }
    }

    /// Every connection's manager with gaps (Settings lists them all).
    var managersWithSkillGaps: [Bot] { bots.filter { isManager($0) && !messagingSkillGaps(manager: $0).isEmpty } }

    /// The all-bots button works: the manager is idle and some gap is not backing off.
    func canInstallSkillsOnAllBots(manager: Bot) -> Bool {
        isIdle(manager) && allBotsSkillQueue[manager.id] == nil && messagingSkillGaps(manager: manager).contains { !$0.installable.isEmpty }
    }

    /// When a backoff on `manager`'s connection ends, so the all-bots views redraw and offer the press again.
    func messagingRetryDates(manager: Bot) -> [Date] {
        messagingSkillGaps(manager: manager).flatMap { skillRetryDates($0.skills, for: $0.bot) }.sorted()
    }

    /// One bot and the messaging skills it needs whose install failed and waits out its backoff: why, and when Retry is back.
    struct SkillWait: Identifiable {
        let bot: Bot; let skills: [BundledSkill]; let retryAt: Date; let reason: String
        var id: UUID { bot.id }
    }

    /// Every Hermes bot (on `manager`'s connection, else on any) with a needed messaging skill whose failed install is
    /// backing off; the gaps leave those out, so without this a failed bot would read as having the skills.
    func messagingSkillWaits(manager: Bot? = nil) -> [SkillWait] {
        let target = manager.map { connection(of: $0) }
        return bots.filter { $0.backend == .hermes && !$0.isReadOnlyArchive && (target == nil || connection(of: $0) == target) }.compactMap { bot in
            let waiting = skills(for: bot).filter {
                Self.messagingSkills.contains($0.name) && skillState($0, for: bot).needsAction && skillInstallBackingOff($0, for: bot)
            }
            guard let first = waiting.compactMap({ skillInstallFailure($0, for: bot) }).min(by: { $0.retryAt < $1.retryAt }) else { return nil }
            return SkillWait(bot: bot, skills: waiting, retryAt: first.retryAt, reason: first.reason)
        }
    }

    /// Settings' line when there is nothing to install or wait for: "needs a manager" or "every bot has them"; nil while
    /// a connection has gaps or a failed install is waiting (their rows say so).
    var allBotsSkillsSummary: String? {
        guard managersWithSkillGaps.isEmpty, messagingSkillWaits().isEmpty else { return nil }
        let unmanaged = bots.contains { $0.backend == .hermes && manager(for: $0) == nil && !missingMessagingSkills(for: $0).isEmpty }
        return unmanaged ? AllBotsSkillCopy.needsManager : AllBotsSkillCopy.allSet
    }

    /// Prefer the signed updater's byte transport. Legacy connections install one bot per turn, with a final encoded
    /// instructions budget checked before sending. A refused bot does not prevent the remaining bots from installing.
    @discardableResult func installSkillsOnAllBots(manager: Bot) -> Bool {
        let gaps = messagingSkillGaps(manager: manager).filter { !$0.installable.isEmpty }
        guard !gaps.isEmpty, isIdle(manager), allBotsSkillQueue[manager.id] == nil else { return false }
        for gap in gaps { skillInstallResults[gap.bot.id] = nil }
        if !usesStagedSkills(on: connection(of: manager)) {
            allBotsSkillQueue[manager.id] = gaps
            open(manager); openThreadID = nil
            return sendNextAllBotsSkillInstall(manager: manager)
        }
        do {
            guard let instructions = try stagedSkillInstructions(manager: manager, profiles: gaps.map { gap in
                stagedProfile(for: gap.bot, skills: gap.skills.map(\.name))
            }) else { return false }
            pendingSkillInstalls[manager.id] = SkillInstallTurn(profile: profile(of: manager), instructions: instructions)
        } catch {
            for gap in gaps {
                recordSkillInstallResult(.init(status: .notSent, detail: "Install not sent: \(error.localizedDescription)"), bot: gap.bot, manager: manager)
            }
            errorMessage = error.localizedDescription; return false
        }
        managementExchanges[manager.id] = nil
        open(manager); openThreadID = nil
        guard send(text: AllBotsSkillCopy.request(gaps.count)) else {
            for gap in gaps {
                recordSkillInstallResult(.init(status: .notSent, detail: "Install not sent: \(errorMessage ?? "the manager could not start the turn")."), bot: gap.bot, manager: manager)
            }
            pendingSkillInstalls[manager.id] = nil; pendingSkillChecks[manager.id] = nil; boxInstallTransport.attempts[manager.id] = nil; return false
        }
        return true
    }

    @discardableResult func sendNextAllBotsSkillInstall(manager: Bot) -> Bool {
        // A queued user message may take the manager's slot between installs. Keep the remaining profiles
        // untouched; runChatTurn (or a Retry's releaseSlot) resumes the batch when that turn finishes.
        guard isIdle(manager) else { return false }
        while let queue = allBotsSkillQueue[manager.id], !queue.isEmpty {
            // 0.6.4: up to allBotsBatchLimit bots per turn (`nextAllBotsBatch`); a refused batch comes back one by one.
            var gaps = [queue[0]]
            do {
                let next = try nextAllBotsBatch(queue, manager: manager)
                gaps = next.gaps
                allBotsSkillQueue[manager.id] = Array(queue.dropFirst(gaps.count))
                noteSkillInstallChecks(gaps.map { ($0.bot, $0.installable) }, manager: manager)
                pendingSkillInstalls[manager.id] = .init(profile: profile(of: gaps[0].bot), instructions: next.instructions)
                allBotsSkillBatch[manager.id] = gaps
                managementExchanges[manager.id] = nil
                // Explicit destination: switching chats during the batch must not redirect the next turn.
                if send(text: AllBotsSkillCopy.request(gaps.count), bot: manager, conversation: manager, replyToID: nil) {
                    allBotsSkillTurn[manager.id] = turn(in: manager)?.token; return true
                }
                throw BackendError.unavailable(errorMessage ?? "The manager could not start the install turn.")
            } catch {
                allBotsSkillQueue[manager.id] = Array(queue.dropFirst(gaps.count)); allBotsSkillBatch[manager.id] = nil
                pendingSkillInstalls[manager.id] = nil; pendingSkillChecks[manager.id] = nil; peerEnableCalls[manager.id] = nil
                for gap in gaps {
                    recordSkillInstallResult(.init(status: .notSent, detail: "Install not sent: \(error.localizedDescription)"), bot: gap.bot, manager: manager)
                }
                errorMessage = error.localizedDescription
            }
        }
        allBotsSkillQueue[manager.id] = nil; allBotsSkillSolo[manager.id] = nil
        return false
    }

    /// `token` is the manager-chat turn that ended (nil: the batch's own). Stop ends the batch only on its install turn; a
    /// stopped queued message lets the next profile go.
    func continueAllBotsSkillInstall(manager: Bot, end: TurnEnd, token: UUID? = nil) {
        let installTurn = token == nil || allBotsSkillTurn[manager.id] == token
        if installTurn { allBotsSkillTurn[manager.id] = nil }
        guard let queue = allBotsSkillQueue[manager.id] else { return }
        if case .stoppedByUser = end, installTurn {
            allBotsSkillQueue[manager.id] = nil; allBotsSkillSolo[manager.id] = nil
            for gap in queue {
                recordSkillInstallResult(.init(status: .notSent, detail: "Install not sent: the batch was stopped."), bot: gap.bot, manager: manager)
            }
            return
        }
        sendNextAllBotsSkillInstall(manager: manager)
    }

    /// A legacy turn's profiles (0.6.4: a batch; dev mode alone); Konrad's original confirmation covers every queued turn.
    /// Outside dev mode a skill is copied from a profile that holds it where it can be (`skillSources`), and one peer call
    /// after the skills covers every profile, without enable while PM blocked this box recently.
    func allBotsSkillInstructions(_ gaps: [SkillGap]) throws -> String? {
        var commands: [String] = [], ops: [String] = [], peers: [String] = []
        for gap in gaps {
            let batched = !gap.bot.skillDevMode
            guard let part = try skillInstallCommands(gap.installable, profile: profile(of: gap.bot), codingOrder: codingOrder(for: gap.bot),
                                                      devMode: gap.bot.skillDevMode, peerInline: !batched,
                                                      sources: batched ? skillSources(for: gap, in: gaps) : [:]) else { return nil }
            commands += part.commands; ops.append(part.op)
            if batched, gap.installable.contains(where: { $0.name == "swarmhub-messages" }) { peers.append(profile(of: gap.bot)) }
        }
        guard !ops.isEmpty else { return nil }
        if let first = gaps.first, !peers.isEmpty {
            let skip = peerEnableKnownBlocked(on: connection(of: first.bot))
            commands.append(PeerPluginEnablement.command(profiles: peers, skipEnable: skip))
            // The single-bot command leaves starting the worker to the line after it, as an inline install does.
            if peers.count == 1, !skip { commands.append("python3 \(SkillLibrary.installPath("swarmhub-messages", profile: peers[0]))/scripts/peer-runtime.py start") }
        }
        let names = gaps.map { "\(profile(of: $0.bot)) (\($0.bot.name))" }.joined(separator: ", ")
        let devNote = gaps.contains { $0.bot.skillDevMode } ? " Skill dev mode is on for some of these bots: a skill a bot changed on this box is kept, not overwritten, and its line says so; that is expected, not an error to fix. Run each `case … esac` block whole, as one call; a peer command inside one runs there, not as its own call." : ""
        return """
        Konrad pressed “\(AllBotsSkillCopy.button)” in SwarmHub and confirmed it once for all of these profiles: \(names). \
        That confirmation is his yes for every one of them: do not ask again. Run exactly these commands in your terminal with \
        the shell (not the file tool), change nothing else, then reply in one short line and end with the block below. \
        \(PeerPluginEnablement.installInstructions)\(devNote) \(AllBotsSkillCopy.speedNote)
        ````sh
        \(commands.joined(separator: "\n"))
        ````
        ```swarmhub
        [\(ops.joined(separator: ","))]
        ```
        """
    }
}

enum AllBotsSkillCopy {
    static let button = "Install SwarmHub skills on all bots"
    static let title = "SwarmHub skills on all bots"
    static func banner(_ count: Int) -> String {
        count == 1 ? "1 bot is missing SwarmHub’s messaging skills" : "\(count) bots are missing SwarmHub’s messaging skills"
    }
    static func request(_ count: Int) -> String { "Install SwarmHub skills on \(count == 1 ? "1 bot" : "all \(count) bots")." }
    /// After the bot names while every gap's install failed and backs off.
    static func retry(_ date: Date?) -> String? { date.map { " · install failed, retry after \($0.formatted(date: .omitted, time: .shortened))" } }
    static func missing(_ skills: [BundledSkill]) -> String { "Missing: " + skills.map(\.name).joined(separator: ", ") }
    static func waiting(_ skills: [BundledSkill], retryAt: Date) -> String {
        "Install failed: " + skills.map(\.name).joined(separator: ", ") + " · retry after \(retryAt.formatted(date: .omitted, time: .shortened))"
    }
    static let confirm = "The manager writes swarmhub-messages and swarmhub-feedback into each of these bots’ profiles. Hermes itself is not changed."
    static let allSet = "Every bot has SwarmHub’s messaging skills."
    /// 0.6.4: start at once, as few calls as possible; a refused copy (`SkillSync`) is that profile's failure, not a retry.
    static let speedNote = "Start with the first command; do not view or load any skill first. Run the skill commands in as few terminal calls as you can, in order. A `python3 - … <<'\(SkillSync.end)'` line copies a skill from another profile on this box and verifies it; if it prints \(SkillSync.failure) or fails, that skill was not written for that profile: leave it out of that profile's skills_installed entry and do not write it another way."
    static let needsManager = "Needs a manager bot on the connection to install."
}
