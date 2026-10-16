import Foundation

/// P38 B: one app action a bot asked for, from the approval card to its outcome. Kept in `app-receipts.json` beside
/// `connected-apps.json` (the last 500); an action that was running when SwarmHub quit is `unknown`, never retried.
/// P48: `failed` is an execution Composio answered with an error (it did not run); a transport failure stays `unknown`.
struct ToolExecutionReceipt: Codable, Identifiable, Sendable, Equatable {
    enum State: String, Codable, Sendable { case awaitingApproval, declined, executing, succeeded, unknown, failed }
    var id: UUID
    var botID: UUID
    var sessionID: String
    var tool: String
    var account: String
    var arguments: String
    var state: State = .awaitingApproval
    var resultID: UUID?
    var outputExcerpt: String?
    var createdAt: Date = .now

    var stateLabel: String {
        switch state {
        case .awaitingApproval: "Waiting for approval"
        case .declined: "Declined"
        case .executing: "Running"
        case .succeeded: "Done"
        case .unknown: "Outcome unknown"
        case .failed: "Failed"
        }
    }
}

/// Full app results, one file per result in the owning bot's folder: a bot can read back only its own results.
struct AppResultStore: Sendable {
    let directory: URL

    func save(_ data: Data, botID: UUID) throws -> UUID {
        let id = UUID(), folder = directory.appending(path: botID.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: id.uuidString.lowercased() + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return id
    }

    func read(_ id: UUID, botID: UUID) throws -> Data {
        let url = directory.appending(path: botID.uuidString.lowercased()).appending(path: id.uuidString.lowercased() + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw ComposioError.accessChanged }
        return try Data(contentsOf: url)
    }
}

extension ConnectedAppsStore {
    static let receiptLimit = 500
    private var receiptsURL: URL { directory.appending(path: "app-receipts.json") }

    func record(_ receipt: ToolExecutionReceipt) throws {
        if let index = receipts.firstIndex(where: { $0.id == receipt.id }) { receipts[index] = receipt }
        else { receipts.append(receipt) }
        if receipts.count > Self.receiptLimit { receipts.removeFirst(receipts.count - Self.receiptLimit) }
        guard canConfigure else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: receiptsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptsURL.path)
    }

    func results() -> AppResultStore { AppResultStore(directory: directory.appending(path: "app-results", directoryHint: .isDirectory)) }

    /// After a restart nothing is waiting or running any more: waiting becomes declined, running becomes unknown.
    func loadReceipts() {
        guard let data = try? Data(contentsOf: receiptsURL) else { return }
        do {
            receipts = try JSONDecoder().decode([ToolExecutionReceipt].self, from: data)
            for var receipt in receipts where receipt.state == .executing || receipt.state == .awaitingApproval {
                receipt.state = receipt.state == .executing ? .unknown : .declined
                try record(receipt)
            }
        } catch { self.error = "App activity could not be read: \(error.localizedDescription)" }
    }
}
