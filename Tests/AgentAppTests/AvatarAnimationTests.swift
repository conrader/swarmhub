import Foundation
import Testing
@preconcurrency import BotAvatarsKit
@testable import AgentApp

@Suite struct AvatarAnimationTests {
    @Test func scenariosSelectTheLibraryStatesAndTapGesture() {
        let cases: [(AvatarMotionMode, BotAvatarState, Int)] = [
            (.idle, .default, 0), (.hovered, .default, 0), (.working, .working, 0),
            (.waiting, .sleeping, 0), (.celebrating, .default, 1)
        ]
        for (mode, state, reaction) in cases {
            let playback = AvatarMotion.playback(mode: mode, context: .list, calm: false, isSelected: true)
            #expect(playback.state == state && playback.reaction == reaction)
            #expect(playback.jump.every == 0 && playback.speed > 0 && playback.speed <= 1)
        }
    }

    @Test func browsingIsCalmAndOnlyCompletionTriggersTheTapGesture() {
        let idle = AvatarMotion.playback(mode: .idle, context: .list, calm: false)
        #expect(idle.state == .default && idle.jump.every == 0 && idle.reaction == 0 && idle.speed == 0.55)
        let selected = AvatarMotion.playback(mode: .idle, context: .list, calm: false, isSelected: true)
        #expect(selected.jump.every == 0 && selected.speed == 0.6 && selected.reaction == 0)
        let focused = AvatarMotion.playback(mode: .idle, context: .focus, calm: false)
        #expect(focused.jump.every == 0 && focused.speed == 0.6 && focused.reaction == 0)
        let working = AvatarMotion.playback(mode: .working, context: .list, calm: false)
        #expect(working.state == .working && working.speed == 0.5)
        let hovered = AvatarMotion.playback(mode: .hovered, context: .list, calm: false)
        #expect(hovered.reaction == 0 && hovered.jump.every == 0)
        #expect(AvatarMotion.playback(mode: .celebrating, context: .list, calm: false).reaction == 1)
    }

    @Test func noContextSelectionOrHoverEnablesRandomJumps() {
        for context in [AvatarMotionContext.list, .focus, .showcase] {
            for selected in [false, true] {
                for mode in [AvatarMotionMode.idle, .hovered] {
                    let playback = AvatarMotion.playback(mode: mode, context: context, calm: false, isSelected: selected)
                    let sim = BotAvatarSim(seed: 0.7, state: playback.state)
                    sim.setJump(playback.jump); BotAvatarGaze.right.apply(to: sim)
                    for _ in 0..<2400 {
                        sim.update(0.025 * playback.speed)
                        #expect(abs(sim.pose.y) <= 2 && abs(sim.pose.yaw) < 1)
                    }
                }
            }
        }
    }

    @Test @MainActor func completionReactionsHaveAPerAgentCooldown() {
        let reactions = AvatarReactions()
        let a = Bot(name: "A"), b = Bot(name: "B")
        let first = Date(timeIntervalSince1970: 100)
        reactions.completed(a, now: first)
        reactions.completed(a, now: first.addingTimeInterval(14.9))
        #expect(reactions.completions[a.id] == first)
        reactions.completed(b, now: first.addingTimeInterval(1))
        #expect(reactions.completions[b.id] == first.addingTimeInterval(1))
        reactions.completed(a, now: first.addingTimeInterval(15))
        #expect(reactions.completions[a.id] == first.addingTimeInterval(15))
    }

    @Test func unselectedNativeIdleKeepsBreathingAndBlinkingWithoutRandomJumps() {
        let playback = AvatarMotion.playback(mode: .idle, context: .list, calm: false)
        let sim = BotAvatarSim(seed: 0.2, state: playback.state)
        sim.setJump(playback.jump); BotAvatarGaze.right.apply(to: sim)
        var greatestBlink = 0.0, lowestSy = 1.0, highestSy = 1.0
        for _ in 0..<2400 {
            sim.update(0.025 * playback.speed)
            #expect(abs(sim.pose.y) <= 2 && abs(sim.pose.yaw) < 1)
            greatestBlink = max(greatestBlink, max(sim.pose.blinkL, sim.pose.blinkR))
            lowestSy = min(lowestSy, sim.pose.sy); highestSy = max(highestSy, sim.pose.sy)
        }
        #expect(greatestBlink > 0.9 && lowestSy < 1 && highestSy > 1)
    }

    @Test func calmUsesLibraryPlaybackControls() {
        for mode in AvatarMotionMode.allCases {
            let normal = AvatarMotion.playback(mode: mode, context: .focus, calm: false)
            let calm = AvatarMotion.playback(mode: mode, context: .focus, calm: true)
            #expect(calm.state == normal.state)
            #expect(calm.speed > 0 && calm.speed < normal.speed)
            #expect(calm.jump.every == 0 && calm.reaction == 0)
            #expect(calm.jump.height == BotAvatarJumpConfig.defaults.height)
        }
    }

    @Test func nativeIdleGazeStaysTowardContentBetweenJumps() {
        for seed in [0.0, 0.17, 0.5, 0.99] {
            for gaze in [BotAvatarGaze.left, .right, .down] {
                let sim = BotAvatarSim(seed: seed)
                sim.setJump(BotAvatarJumpConfig(every: 0))
                gaze.apply(to: sim)
                for frame in 0..<1200 {
                    sim.update(1.0 / 60)
                    if frame < 180 { continue } // Allow the native pointer-following springs to settle.
                    let pose = sim.pose
                    switch gaze {
                    case .left: #expect(pose.yaw < 0 && pose.lookX < 0)
                    case .right: #expect(pose.yaw > 0 && pose.lookX > 0)
                    case .down: #expect(pose.pitch < 0 && pose.lookY > 0)
                    case .forward: break
                    }
                    #expect(abs(pose.yaw) < 1 && pose.sx > 0 && pose.sy > 0)
                }
            }
        }
    }

    @Test func nativeWorkingKeepsHopsSpinsLaughsAndSquash() {
        let sim = BotAvatarSim(seed: 0.2, state: .working)
        BotAvatarGaze.right.apply(to: sim)
        var lowestY = 0.0, greatestYaw = 0.0, greatestLaugh = 0.0, smallestSy = 1.0
        for _ in 0..<800 {
            sim.update(0.025)
            lowestY = min(lowestY, sim.pose.y)
            greatestYaw = max(greatestYaw, sim.pose.yaw)
            greatestLaugh = max(greatestLaugh, sim.pose.laugh)
            smallestSy = min(smallestSy, sim.pose.sy)
        }
        #expect(lowestY < -20 && greatestYaw > 5 && greatestLaugh > 0.8 && smallestSy < 0.9)
    }

    @Test func nativeIdleKeepsBlinksAndAutomaticFlipsWithoutHover() {
        let sim = BotAvatarSim(seed: 0.2)
        BotAvatarGaze.left.apply(to: sim)
        var lowestY = 0.0, greatestYaw = 0.0, greatestBlink = 0.0
        for _ in 0..<1200 {
            sim.update(0.025)
            lowestY = min(lowestY, sim.pose.y)
            greatestYaw = max(greatestYaw, sim.pose.yaw)
            greatestBlink = max(greatestBlink, max(sim.pose.blinkL, sim.pose.blinkR))
        }
        #expect(lowestY < -20 && greatestYaw > 5 && greatestBlink > 0.9)
    }

    @Test func nativeTapProvidesACompleteReactionAndReturnsToIdle() {
        let sim = BotAvatarSim(seed: 0.2)
        sim.setJump(BotAvatarJumpConfig(every: 0))
        BotAvatarGaze.right.apply(to: sim)
        sim.poke()
        var lowestY = 0.0, greatestYaw = 0.0
        for _ in 0..<120 {
            sim.update(1.0 / 60)
            lowestY = min(lowestY, sim.pose.y)
            greatestYaw = max(greatestYaw, sim.pose.yaw)
        }
        #expect(lowestY < -20 && greatestYaw > 5)
        #expect(abs(sim.pose.y) <= 2 && abs(sim.pose.yaw) < 1)
        #expect(sim.state == .default)
    }

    @Test func staticFacingMatchesTheContentTarget() {
        #expect(BotAvatarGaze.left.restPose().yaw < 0 && BotAvatarGaze.left.restPose().lookX < 0)
        #expect(BotAvatarGaze.right.restPose().yaw > 0 && BotAvatarGaze.right.restPose().lookX > 0)
        #expect(BotAvatarGaze.down.restPose().pitch < 0 && BotAvatarGaze.down.restPose().lookY > 0)
    }

    @Test @MainActor func approvalsOnlyAffectTheirBotAndGroupSession() {
        let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let a = Bot(name: "A"), b = Bot(name: "B")
        let group = GroupChat(name: "G", memberIDs: [a.id, b.id]), other = GroupChat(name: "H", memberIDs: [a.id])
        group.sessions[a.id.uuidString.lowercased()] = "synthetic-server-session"
        store.approvals = [.init(id: UUID(), title: "Test", summary: "", draft: nil, command: "cat /tmp/test", botID: a.id,
                                 sessionID: "synthetic-server-session")]
        #expect(store.hasPendingApproval(a) && !store.hasPendingApproval(b))
        #expect(store.hasPendingApproval(a, in: group) && !store.hasPendingApproval(a, in: other))
        #expect(!store.hasPendingApproval(b, in: group))
    }

    @Test @MainActor func onlySuccessfulNonemptyRepliesPublishCompletionReactions() async throws {
        for result in ["success", "failure", "empty", "cancel"] {
            let backend = AvatarCompletionBackend(result: result)
            let bot = Bot(name: "Completion test", backend: .hermes, hermesSessionID: "synthetic-session")
            let store = AppStore(storeURL: temporaryStore(), autoConfigureHermes: false, backendFactory: { _ in backend },
                                 keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
            store.bots = [bot]; store.selectedBot = bot
            #expect(store.send(text: "Test"))
            if result == "cancel" {
                try await waitUntil { bot.messages.last?.content == "Partial reply" }
                store.stop()
            }
            try await waitUntil { !store.anyTurnRunning }
            #expect((AvatarReactions.shared.completions[bot.id] != nil) == (result == "success"))
        }
    }
}

private struct AvatarCompletionBackend: AgentBackend {
    let kind = BackendKind.hermes
    let result: String
    func send(_ request: AgentRequest) async throws -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if result != "empty" { continuation.yield(.token("Partial reply")) }
                if result == "cancel" { await hangUntilCancelled() }
                continuation.yield(result == "failure" ? .failed("Synthetic failure") : .completed)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func listSessions() async throws -> [BackendSession] { [] }
    func cancel(sessionID: String) async throws -> StopOutcome { .disconnectedLegacy }
    func resolveApproval(id: UUID, approved: Bool) async throws {}
    func testConnection() async throws -> String { "Synthetic" }
}
