import Darwin
import Foundation
import Testing
@testable import AgentApp

/// The P10.0 live run hung after step (e): `HeadlessGrok.run` blocked the main thread on a semaphore while steps
/// (f)/(g) waited for the main actor. These tests block the main thread the same way and require the step (f)/(g)
/// path to finish anyway, which it can only do if it is not main-actor isolated.
@MainActor struct GrokSpikeIsolationTests {
    private static func soon() -> DispatchTime { .now() + .seconds(10) }

    @Test func blockingRunExecutesOffTheMainThread() {
        #expect(pthread_main_np() != 0)
        let onMain = HeadlessGrokLive.blockingRun(timeout: Self.soon()) { pthread_main_np() != 0 }
        #expect(onMain == false)
    }

    @Test func liveStepsPathFinishesWhileMainThreadIsBlocked() throws {
        // Empty secrets fail at the first guard, before any Keychain read or network call; the point is that
        // entering and leaving liveSteps never needs the main actor.
        let outcome = try #require(HeadlessGrokLive.blockingRun(timeout: Self.soon()) {
            await HeadlessGrokLive.liveSteps(agentID: "agent", secretsData: Data(), key: [], version: "0.0.0")
        })
        #expect(outcome.stepF == nil)
        #expect(outcome.stepG == nil)
    }

    @Test func mainActorHopUnderBlockingRunTimesOut() {
        // Control: work that needs the main actor (the original bug) cannot finish while main waits.
        let result = HeadlessGrokLive.blockingRun(timeout: .now() + .milliseconds(500)) { await MainActor.run { 1 } }
        #expect(result == nil)
    }
}
