import Foundation

/// Per-origin local routing and crash-safe receipt reconciliation metadata, never box authority.
/// Shared by Mac and iOS (P5d). There is deliberately no app control to clear device-required routing or change box mode.
public final class DeviceApprovalSettings: @unchecked Sendable {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults) { self.defaults = defaults }
    private func key(_ origin: String) -> String { "approvals.v2." + DeviceApprovalWire.digest(Data(origin.utf8)) }
    // Presence is sticky, even if a feature flag writes false or corrupts the value.
    public func isRequired(_ origin: String) -> Bool { defaults.object(forKey: key(origin) + ".required") != nil }
    public func confirmOperatorCutover(_ origin: String) { defaults.set(true, forKey: key(origin) + ".required") }
    public func hasAttempt(origin: String, task: String) -> Bool { defaults.object(forKey: key(origin) + "." + task) != nil }
    public func attempt(origin: String, task: String) throws -> [String: JSONValue]? {
        guard hasAttempt(origin: origin, task: task) else { return nil }
        guard let data = defaults.data(forKey: key(origin) + "." + task) else { throw ManagedControlError.invalidRecord }
        guard let result = try DeviceApprovalJSON.parse(data).objectValue else { throw ManagedControlError.invalidRecord }
        return result
    }
    public func remember(_ signed: [String: JSONValue], origin: String, task: String) throws {
        let data = try DeviceApprovalWire.canonical(.object(signed))
        defaults.set(data, forKey: key(origin) + "." + task)
        // The decision may be committed even if this process dies before its acknowledgement.
        guard defaults.synchronize(), defaults.data(forKey: key(origin) + "." + task) == data else { throw ManagedControlError.rejected }
    }
    public func clearRefusedAttempt(origin: String, task: String) throws {
        let name = key(origin) + "." + task
        let previous = defaults.object(forKey: name)
        defaults.removeObject(forKey: name)
        guard defaults.synchronize(), !hasAttempt(origin: origin, task: task) else {
            defaults.set(previous, forKey: name)
            _ = defaults.synchronize()
            throw ManagedControlError.rejected
        }
    }
    public func clearExpiredAttempt(_ expected: [String: JSONValue], origin: String, task: String) throws {
        guard try attempt(origin: origin, task: task) == expected else { throw ManagedControlError.rejected }
        try clearRefusedAttempt(origin: origin, task: task)
    }
}
