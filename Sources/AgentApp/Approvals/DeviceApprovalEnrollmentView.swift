import SwiftUI

/// Local enrollment preparation only. No model turn, enrollment RPC, or remote mode switch.
struct DeviceApprovalEnrollmentSection: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        Section("Device-signed managed approvals") {
            ForEach(origins, id: \.self) { origin in
                DeviceApprovalEnrollmentRow(origin: origin, settings: DeviceApprovalSettings(defaults: store.defaults), keys: store.approvalKeys)
            }
            Text("Enroll this Mac from each box’s console or authenticated SSH session. Native Hermes approvals use their existing connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var origins: [String] {
        let addresses = store.hermesConnections.map(\.target)
        return Array(Set(addresses.compactMap { try? DeviceApprovalWire.origin(address: $0) })).sorted()
    }
}

private struct DeviceApprovalEnrollmentRow: View {
    let origin: String
    let settings: DeviceApprovalSettings
    let keys: any DeviceApprovalKeyStore
    @State private var identity: DeviceApprovalIdentity?
    @State private var required = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(origin).fontWeight(.medium).textSelection(.enabled)
            Text(required ? "Operator confirmed device-required routing" : identity == nil ? "Legacy routing · enrollment not checked" : "Key ready · box enrollment not checked")
                .font(.caption).foregroundStyle(.secondary)
            Button(identity == nil ? "Show this Mac’s approval key" : "Reload approval key", action: load)
            if let identity {
                LabeledContent("Key ID", value: identity.keyID).textSelection(.enabled)
                LabeledContent("Ed25519 public key", value: identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                Text("On the box: python3 swarm_devices.py enroll \(identity.keyID) \(identity.publicKey) --profile <decider-profile>")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("After enrollment, the operator runs python3 swarm_devices.py mode required on the box. This app cannot change that mode.")
                    .font(.caption).foregroundStyle(.secondary)
                if !required {
                    Button("I enabled device-required mode on this box") {
                        settings.confirmOperatorCutover(origin); required = true
                    }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.onAppear { required = settings.isRequired(origin) }
    }
    private func load() {
        do { identity = try DeviceApprovalIdentity.loadOrCreate(box: origin, store: keys); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
