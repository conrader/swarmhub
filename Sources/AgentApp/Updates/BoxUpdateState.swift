import Foundation

/// Detection only: updater status and this Mac's defaults are writable within their account boundaries.
/// Keep the last reported version too, so a regression warning survives relaunch while the box is offline.
struct BoxUpdateState: Codable, Equatable {
    private(set) var highestBundleVersion: Int64 = 0
    private(set) var reportedBundleVersion: Int64? = nil

    var regression: Bool { reportedBundleVersion.map { $0 < highestBundleVersion } ?? false }

    mutating func observe(_ status: BoxUpdaterStatus) {
        guard let version = status.bundle?.bundle_version, version >= 0 else { return }
        reportedBundleVersion = version
        highestBundleVersion = max(highestBundleVersion, version)
    }

    /// A value captured by the button, never expanded to another box or a newer pending version.
    struct Confirmation: Equatable, Sendable {
        let connection: String
        let version: Int64
        let manifest: String

        init?(connection: String, status: BoxUpdaterStatus) {
            guard status.state == "pending_confirm", let pending = status.pending_confirm,
                  !pending.code.isEmpty, let bundle = status.bundle, bundle.bundle_version > 0,
                  pending.bundle_version == bundle.bundle_version else { return nil }
            self.connection = connection
            version = bundle.bundle_version
            manifest = bundle.manifest_sha256
        }

        var command: String { StagedInstall.confirmCommand(version: version) }
        var title: String { "Apply code update \(version) on \(connection)" }

        func accepted(_ status: BoxUpdaterStatus) -> Bool {
            status.state == "current" && status.pending_confirm == nil &&
            status.bundle?.bundle_version == version && status.bundle?.manifest_sha256 == manifest &&
            status.applied_bundle_version == version && status.confirmed_version == version &&
            status.last?.command == "apply" && status.last?.verdict == "accept" && status.last?.bundle_version == version
        }
    }
}

/// Confirmation receipt followed by an independent status read. Neither assistant prose nor a status read alone
/// can acknowledge a click. A failed apply cannot reuse an old successful status for the same bundle.
struct BoxUpdateConfirmCall {
    let confirmation: BoxUpdateState.Confirmation
    private var callID: String?
    private var applied = false
    private var statusCall = UpdaterStatusCall()
    private(set) var succeeded = false
    private(set) var failure: BoxUpdaterStatus?

    init(_ confirmation: BoxUpdateState.Confirmation) { self.confirmation = confirmation }

    mutating func consume(_ tool: ToolEvent, previous: BoxUpdaterStatus?) -> BoxUpdaterStatus? {
        guard ["terminal", "shell", "execute", "bash"].contains(tool.name) else { return nil }
        if tool.phase == .started, tool.command == confirmation.command {
            callID = tool.callID; applied = false; succeeded = false; failure = nil
        } else if let expected = callID, tool.callID == expected, tool.phase == .completed || tool.phase == .failed {
            callID = nil
            applied = tool.phase == .completed && tool.result.flatMap(BoxUpdaterStatus.decode).map(confirmation.accepted) == true
            if !applied {
                failure = BoxUpdaterStatus.failedResult(tool.result ?? "", previous: previous)
            }
            // Observe actual updater status even on version_changed; this is not a success receipt.
            return tool.result.flatMap { BoxUpdaterStatus.decode(BoxUpdaterStatus.commandOutput($0)) }
        }
        guard applied, let status = statusCall.consume(tool) else { return nil }
        succeeded = confirmation.accepted(status)
        return status
    }
}

extension AppStore {
    func boxUpdateState(on target: String) -> BoxUpdateState {
        defaults.data(forKey: "updates.box-state." + target)
            .flatMap { try? JSONDecoder().decode(BoxUpdateState.self, from: $0) } ?? BoxUpdateState()
    }

    /// Only matched, decoded updater readings enter the regression record, never local failure overlays.
    func noteBoxUpdaterStatus(_ status: BoxUpdaterStatus, on target: String) {
        var record = boxUpdateState(on: target)
        record.observe(status)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: "updates.box-state." + target) }
        boxInstallTransport.status[target] = status
        objectWillChange.send()
    }

    func boxCodeConfirmation(for bot: Bot) -> BoxUpdateState.Confirmation? {
        let target = connection(of: bot)
        return boxInstallTransport.status[target].flatMap { .init(connection: target, status: $0) }
    }
}
