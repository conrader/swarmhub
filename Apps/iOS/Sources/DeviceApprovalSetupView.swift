import SwiftUI
import SwarmHubCore

/// Local enrollment preparation only: shows this phone's approval key per box. No enrollment RPC, no remote mode
/// switch, and no control that clears device-required routing once confirmed.
struct DeviceApprovalSetupSection: View {
    @Environment(MobileStore.self) private var store
    var body: some View {
        let origins = ManagedApprovalScope.enrollableOrigins(store.profiles)
        if !store.demo, !origins.isEmpty {
            Section {
                ForEach(origins, id: \.self) { origin in DeviceApprovalSetupRow(origin: origin) }
            } header: { Text("Managed approvals") } footer: {
                Text("Enroll this phone from each box’s console or authenticated SSH session. Managed approvals appear only after the box is in device-required mode. Native Hermes approvals keep using the profile connection.")
            }
        }
    }
}

private struct DeviceApprovalSetupRow: View {
    let origin: String
    @Environment(ManagedApprovalStore.self) private var managed
    @State private var identity: DeviceApprovalIdentity?
    @State private var required = false
    @State private var confirm = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(origin).fontWeight(.medium).textSelection(.enabled)
            Text(required ? "Device-required · managed approvals shown" : identity == nil ? "Not device-required · managed approvals hidden" : "Key ready · box enrollment not checked")
                .font(.caption).foregroundStyle(.secondary)
            Button(identity == nil ? "Show this phone’s approval key" : "Reload approval key", action: load)
            if let identity {
                LabeledContent("Key ID", value: identity.keyID).textSelection(.enabled)
                Text(identity.publicKey).font(.caption.monospaced()).textSelection(.enabled)
                Text("On the box: python3 swarm_devices.py enroll \(identity.keyID) \(identity.publicKey) --profile <decider-profile>")
                    .font(.caption.monospaced()).textSelection(.enabled)
                Text("After enrollment, the operator runs python3 swarm_devices.py mode required on the box. This app cannot change that mode.")
                    .font(.caption).foregroundStyle(.secondary)
                if !required { Button("I enabled device-required mode on this box") { confirm = true } }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear { required = managed.settings.isRequired(origin) }
        .confirmationDialog("Show managed approvals for this box on this phone?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Yes, the box is device-required") { managed.confirmCutover(origin); required = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Confirm only after the operator enrolled this phone and ran mode required. This cannot be undone from the app.") }
    }

    private func load() {
        do { identity = try managed.identity(origin: origin); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
