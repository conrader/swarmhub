import Foundation
import SwarmHubCore

// P5d moved the device-signed approval client into SwarmHubCore so iOS links the same code.
// The Mac keeps its names through these aliases; behaviour, keys, defaults and wire bytes are unchanged.
typealias JSONValue = SwarmHubCore.JSONValue
typealias ManagedRecord = SwarmHubCore.ManagedRecord
typealias ManagedControlError = SwarmHubCore.ManagedControlError
typealias DeviceApprovalJSON = SwarmHubCore.DeviceApprovalJSON
typealias DeviceApprovalWire = SwarmHubCore.DeviceApprovalWire
typealias DeviceApprovalIdentity = SwarmHubCore.DeviceApprovalIdentity
typealias DeviceApprovalKeyStore = SwarmHubCore.DeviceApprovalKeyStore
typealias DeviceApprovalSettings = SwarmHubCore.DeviceApprovalSettings

extension DeviceApprovalEnvironment {
    /// The Mac's QA boundary and test-run network guard, exactly where the Mac client applied them before P5d.
    static let mac = DeviceApprovalEnvironment(prepare: { request in
        #if DEBUG
        if QAMode.enabled { return try QAMode.boundary.native(request) }
        #endif
        return request
    }, configure: { TestRunGuard.guarded($0) })
}

/// The Mac's approval Keychain: the shared store behind the Mac test-run guard.
struct ApprovalKeychainStore: DeviceApprovalKeyStore {
    static let service = DeviceApprovalKeychain.service
    private let keychain = DeviceApprovalKeychain(refuses: { TestRunGuard.refuses($0) })
    func read(account: String) throws -> Data? { try keychain.read(account: account) }
    func insert(_ seed: Data, account: String) throws { try keychain.insert(seed, account: account) }
}

/// Direct app → box v2 only, through the shared client with the Mac environment.
enum DeviceApprovalClient {
    static func request(address: String, profile: String, verb: String, task: String, input: Data?,
                        identity: DeviceApprovalIdentity, settings: DeviceApprovalSettings, reviewed: ManagedRecord? = nil,
                        session: URLSession? = nil, timeout: TimeInterval = 15) async throws -> ManagedRecord {
        try await DeviceSignedApprovalClient.request(address: address, profile: profile, verb: verb, task: task, input: input,
                                                     identity: identity, settings: settings, reviewed: reviewed,
                                                     session: session, timeout: timeout, environment: .mac)
    }

    static func read(_ verb: String, origin: String, profile: String, task: String, identity: DeviceApprovalIdentity,
                     session: URLSession?, timeout: TimeInterval) async throws -> [String: JSONValue] {
        try await DeviceSignedApprovalClient.read(verb, origin: origin, profile: profile, task: task, identity: identity,
                                                  session: session, timeout: timeout, environment: .mac)
    }

    static func decodeRecord(_ value: JSONValue) throws -> ManagedRecord { try DeviceSignedApprovalClient.decodeRecord(value) }

    static func validateReceipt(_ record: ManagedRecord, origin: String, profile: String, task: String,
                                identity: DeviceApprovalIdentity, expected: [String: JSONValue]?) throws {
        try DeviceSignedApprovalClient.validateReceipt(record, origin: origin, profile: profile, task: task,
                                                       identity: identity, expected: expected)
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
