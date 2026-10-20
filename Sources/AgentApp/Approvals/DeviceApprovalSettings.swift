import Foundation

/// Per-origin local routing and crash-safe receipt reconciliation metadata, never box authority.
/// There is deliberately no app control to clear device-required routing or change box mode.
final class DeviceApprovalSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ origin: String) -> String { "approvals.v2." + DeviceApprovalWire.digest(Data(origin.utf8)) }
    // Presence is sticky, even if a feature flag writes false or corrupts the value.
    func isRequired(_ origin: String) -> Bool { defaults.object(forKey: key(origin) + ".required") != nil }
    func confirmOperatorCutover(_ origin: String) { defaults.set(true, forKey: key(origin) + ".required") }
    func hasAttempt(origin: String, task: String) -> Bool { defaults.object(forKey: key(origin) + "." + task) != nil }
    func attempt(origin: String, task: String) throws -> [String: JSONValue]? {
        guard hasAttempt(origin: origin, task: task) else { return nil }
        guard let data = defaults.data(forKey: key(origin) + "." + task) else { throw ManagedControlError.invalidRecord }
        guard let result = try DeviceApprovalJSON.parse(data).objectValue else { throw ManagedControlError.invalidRecord }
        return result
    }
    func remember(_ signed: [String: JSONValue], origin: String, task: String) throws {
        let data = try DeviceApprovalWire.canonical(.object(signed))
        defaults.set(data, forKey: key(origin) + "." + task)
        // The decision may be committed even if this process dies before its acknowledgement.
        guard defaults.synchronize(), defaults.data(forKey: key(origin) + "." + task) == data else { throw ManagedControlError.rejected }
    }
    func clearRefusedAttempt(origin: String, task: String) throws {
        let name = key(origin) + "." + task
        let previous = defaults.object(forKey: name)
        defaults.removeObject(forKey: name)
        guard defaults.synchronize(), !hasAttempt(origin: origin, task: task) else {
            defaults.set(previous, forKey: name)
            _ = defaults.synchronize()
            throw ManagedControlError.rejected
        }
    }
    func clearExpiredAttempt(_ expected: [String: JSONValue], origin: String, task: String) throws {
        guard try attempt(origin: origin, task: task) == expected else { throw ManagedControlError.rejected }
        try clearRefusedAttempt(origin: origin, task: task)
    }
}

extension ManagedRemoteControl {
    /// Legacy dispatch calls the original v1 implementation unchanged, without touching approval keys.
    static func requestForBox(address: String, profile: String, key: String, verb: String, task: String, input: Data?,
                              settings: DeviceApprovalSettings, approvalKeys: any DeviceApprovalKeyStore,
                              reviewed: ManagedRecord? = nil, session: URLSession? = nil, timeout: TimeInterval = 15) async throws -> ManagedRecord {
        let box = try? origin(address: address)
        if let box, settings.isRequired(box) {
            let identity: DeviceApprovalIdentity
            do { identity = try DeviceApprovalIdentity.loadOrCreate(box: box, store: approvalKeys) }
            catch {
                if verb == "decide" { throw ManagedControlError.unsent(error.localizedDescription) }
                throw error
            }
            return try await DeviceApprovalClient.request(address: address, profile: profile, verb: verb, task: task,
                                                          input: input, identity: identity, settings: settings,
                                                          reviewed: reviewed, session: session, timeout: timeout)
        }
        return try await request(address: address, profile: profile, key: key, verb: verb, task: task,
                                 input: input, session: session, timeout: timeout)
    }
}
