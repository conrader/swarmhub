import Foundation

/// Saved with the bot. A queued step has never been submitted. A running step may
/// already have reached the agent, even when the transcript has no reply yet.
struct ChatGoal: Codable, Equatable {
    enum State: String, Codable {
        case queued, running, waiting, completed, stopped

        var active: Bool { self != .completed && self != .stopped }
    }

    struct Report: Codable {
        enum Outcome: String, Codable { case progress, complete, blocked, noProgress = "no_progress", failed }
        let iteration: UUID
        let outcome: Outcome
        let evidence: String

        static func read(_ reply: String, for attempt: UUID) -> (report: Self, prose: String)? {
            let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = text.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
            guard let report = try? JSONDecoder().decode(Self.self, from: Data(text[start...].utf8)),
                  report.iteration == attempt, !report.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (report, String(text[..<start]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    struct Destination: Codable, Equatable {
        let serverID: String
        let connection: HerdrServer.Kind
        let address: String
        let sshHost: String
        let sshUser: String
        let agent: String
        let sessionID: String
    }
    let id: UUID
    let objective: String
    let destination: Destination
    var state = State.queued
    var iteration = 0
    var attempt: UUID?
    var detail = ""
    private var stalls = 0
    private var progressEvidence: [String] = []

    init(objective: String, destination: Destination) {
        id = UUID()
        self.objective = objective
        self.destination = destination
    }

    mutating func begin() -> UUID {
        let token = UUID()
        attempt = token
        iteration += 1
        state = .running
        return token
    }

    func request(for token: UUID) -> String {
        let instructions = """
        Work on one step toward this goal: \(objective)
        Use the normal workspace approval process. If input or approval is needed, wait for the person.
        End your reply with one JSON line for this step. Set outcome to progress, complete, blocked, no_progress, or failed.
        For progress name the new result. For complete give evidence that the entire objective was met. Otherwise explain what is needed.
        {"iteration":"\(token.uuidString)","outcome":"...","evidence":"..."}
        """
        guard !detail.isEmpty else { return instructions }
        // An objective that fit on the first step must still fit on its next step.
        let lead = "\nLast result: "
        let room = HerdrClient.messageBytes - instructions.utf8.count - lead.utf8.count
        return room > 0 ? instructions + lead + HerdrClient.plain(detail, bytes: room) : instructions
    }

    mutating func finish(_ report: Report) {
        guard state == .running, attempt == report.iteration else { return }
        attempt = nil
        detail = String(report.evidence.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        switch report.outcome {
        case .complete: state = .completed
        case .blocked: state = .waiting
        case .failed, .noProgress:
            stalls += 1
            state = .queued
        case .progress:
            let key = detail.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if progressEvidence.contains(key) { stalls += 1 }
            else {
                progressEvidence.append(key)
                if progressEvidence.count > 32 { progressEvidence.removeFirst() }
                stalls = 0
            }
            state = .queued
        }
        if state == .queued, stalls >= 2 {
            wait("Two steps produced no new progress. " + detail)
        }
    }

    mutating func wait(_ reason: String) {
        attempt = nil
        state = .waiting
        detail = reason
    }

    mutating func resume() {
        guard state == .waiting else { return }
        state = .queued
        stalls = 0
        progressEvidence.removeAll()
    }

    mutating func stop() {
        state = .stopped
        attempt = nil
        detail = "Stopped by you."
    }
}
