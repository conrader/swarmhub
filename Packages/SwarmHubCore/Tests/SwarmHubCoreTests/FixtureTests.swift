import Foundation
import Testing
@testable import SwarmHubCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWARMHUB_IOS_FIXTURE_URL"] != nil))
struct FixtureTests {
    private func client(profile: String = "research") throws -> HermesClient {
        let raw = try #require(ProcessInfo.processInfo.environment["SWARMHUB_IOS_FIXTURE_URL"])
        let url = try #require(URL(string: raw))
        guard url.host == "127.0.0.1", url.scheme == "http" else { throw CoreError.invalidAddress }
        return HermesClient(address: try ConnectionAddress(raw, profile: profile, allowLoopbackHTTP: true), key: "mobile-fixture")
    }

    @Test func realHTTPSetupHistoryStreamingAndDecision() async throws {
        let backend = try client()
        #expect(try await backend.verify().capabilities.sessions)
        let id = try await backend.createSession(title: "Synthetic iOS integration")
        #expect(try await backend.sessions().contains { $0.id == id })
        #expect(try await backend.messages(sessionID: id).isEmpty)
        var output = ""; var runID: String?; var terminal: TurnState?
        for try await event in backend.stream(sessionID: id, text: "fixture task") {
            switch event {
            case .started(let id): runID = id
            case .delta(let value): output += value
            case .approval(let request): try await backend.resolve(request, approved: true)
            case .terminal(let state): terminal = state
            default: break
            }
        }
        #expect(output == "Synthetic reply.")
        #expect(terminal == .completed)
        let history = try await backend.messages(sessionID: id)
        #expect(history.map(\.role) == [.user, .assistant])
        #expect(history.last?.text == output)
        let run = try #require(runID)
        #expect(try await backend.run(runID: run).state == .completed)
        try await backend.steer(runID: run, text: "synthetic guidance")
        try await backend.stop(runID: run)
        #expect(try await backend.run(runID: run).state == .cancelled)
    }

    @Test func realHTTPDisconnectRetainsUncertainOutcome() async throws {
        let backend = try client()
        let id = try await backend.createSession(title: "Interrupted synthetic turn")
        var runID: String?; var partial = ""
        do {
            for try await event in backend.stream(sessionID: id, text: "interrupt") {
                if case .started(let run) = event { runID = run }
                if case .delta(let value) = event { partial += value }
            }
            Issue.record("EOF cannot complete an interrupted turn")
        } catch { #expect(error as? CoreError == .interruptedStream) }
        #expect(partial == "Synthetic reply.")
        let run = try #require(runID)
        #expect(try await backend.run(runID: run).state == nil)
        #expect(try await backend.messages(sessionID: id).count == 1)
    }

    @Test func realHTTPProfileIsolation() async throws {
        let mismatch = try client(profile: "mismatch")
        await #expect(throws: (any Error).self) { try await mismatch.verify() }
    }
}
