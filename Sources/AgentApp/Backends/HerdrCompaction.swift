import Foundation

/// The summary of a conversation's older part, written by a one-off agent on the bot's own server, from the bot's
/// own agent program and model, so it runs on what the person already uses there and the app names no model.
/// It is never the bot's own agent: that would put the whole old transcript into the bot's real conversation.
/// The older part goes as attached files, four with a message; a longer one goes in several messages, each asking
/// for the complete summary so far, and the last reply is the summary. The agent is ended afterwards, also when the
/// work failed, was cancelled or took too long.
extension HerdrClient {
    /// The one-off agent's name on the server: `handoff-` and twelve characters of the conversation's id. A bot's
    /// own agent ends in six characters of its id and a group agent in twenty-four, so neither can be taken for it,
    /// nor it for them (`liveAgent` matches the part after the last `-`).
    static func compactorName(for id: UUID) -> String {
        "handoff-" + String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// The work took longer than it may.
    struct SummaryTimeout: Error, Equatable {}

    /// What the one-off agent is asked: the summary of the first files, then the complete summary again with what
    /// each further set of files adds.
    static func summaryPrompt(part: Int, of parts: Int) -> String {
        let reply = "Reply with the summary only, as plain text of at most 6000 characters: no greeting, no question, and do nothing else."
        if part <= 1 {
            let more = parts > 1 ? " More files follow in \(parts - 1) further message\(parts == 2 ? "" : "s")." : ""
            return """
            You are preparing a handover. The attached files are the older part of a conversation between a person and their assistant, oldest first. Each message starts with [#number time speaker]. Secrets were replaced by \(GrokRedactor.marker); leave them so.\(more)
            Read every attached file from start to end. Then write a summary for the assistant that will continue this conversation: what the person wants and how they like to work, what was decided, what was done and with what result, what is still open, and the names, numbers, paths and dates worth keeping.
            \(reply)
            """
        }
        return """
        The attached files continue the same conversation (message \(part) of \(parts)). Read each from start to end. Then write the complete summary again: your previous summary with what these files add.
        \(reply)
        """
    }

    /// Has a one-off agent named `name` summarise `files` and returns what it wrote. The agent is ended before this
    /// returns or throws. Throws what the delivery or the wait threw, or `SummaryTimeout` after `limit`.
    func summarise(_ files: [TaskFile], name: String, template: String?, model: String?, limit: Duration) async throws -> String {
        guard !files.isEmpty else { throw Failure.silent }
        let rounds: [[TaskFile]] = stride(from: 0, to: files.count, by: 4).map { from in Array(files[from..<min(from + 4, files.count)]) }
        // One left behind by a run that was cut short would take these files into its old session.
        try await endAgents(named: name)
        let client = self
        do {
            let text = try await Self.within(limit) { try await client.summaryRounds(rounds, name: name, template: template, model: model) }
            await endAfterwards(named: name)
            return text
        } catch {
            await endAfterwards(named: name)
            throw error
        }
    }

    /// One message per set of files; the reply to the last one is the summary.
    func summaryRounds(_ rounds: [[TaskFile]], name: String, template: String?, model: String?) async throws -> String {
        var summary = ""
        for (index, files) in rounds.enumerated() {
            try Task.checkCancellation()
            let turn = try await deliver(Self.summaryPrompt(part: index + 1, of: rounds.count), name: name, template: template, model: model, files: files)
            summary = try await reply(to: turn)
        }
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.silent }
        return text
    }

    /// Ends every running agent of exactly this name. For one-off agents only: never by the id ending `liveAgent`
    /// also accepts.
    func endAgents(named name: String) async throws {
        let running = try await workspace().agents.filter { $0.isLive && $0.name == name }
        for agent in running { try await end(agent) }
    }

    /// `endAgents` from a task of its own, so that it also runs when the caller was cancelled; a failure is left be
    /// (the server ends an agent nobody writes to).
    private func endAfterwards(named name: String) async {
        let client = self
        await Task.detached { _ = try? await client.endAgents(named: name) }.value
    }

    /// What `work` returns, unless it takes longer than `limit`: then it is cancelled and `SummaryTimeout` is thrown.
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self, returning: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SummaryTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SummaryTimeout() }
            return first
        }
    }
}
