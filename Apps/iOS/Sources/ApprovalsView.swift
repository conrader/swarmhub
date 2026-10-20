import SwiftUI
import SwarmHubCore

struct ApprovalsView: View {
    @Environment(MobileStore.self) private var store
    @Environment(ManagedApprovalStore.self) private var managed
    var body: some View {
        NavigationStack {
            List {
                AvailabilityNote(text: "Manual requests from this phone’s live runs. Background delivery, a complete server inbox and shared decision history require later milestones.")
                if store.approvals.isEmpty {
                    ContentUnavailableView("No requests loaded", systemImage: "checkmark.shield", description: Text("Requests appear during a live turn. Reopen an interrupted conversation to check its server status."))
                }
                ForEach(store.approvals) { item in
                    NavigationLink { ApprovalDetailView(item: item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(store.profiles.first { $0.id == item.agentID }?.name ?? "Agent").font(.caption).foregroundStyle(.secondary)
                            Text(item.request.title).font(.headline)
                            Text(item.request.command ?? "Exact action unavailable").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.padding(.vertical, 6)
                    }
                }
                // Device-signed managed approvals; renders nothing unless a connected box is device-required.
                ManagedApprovalsSection()
            }.navigationTitle("Approvals")
            // Asks opted-in boxes for their mode and pending operations even while the managed section is hidden.
            .task(id: managed.routingRevision) { await refreshManaged() }
            .refreshable { await refreshManaged() }
        }
    }
    private func refreshManaged() async { await managed.refresh(profiles: store.profiles, caches: store.caches, demo: store.demo) }
}

struct ApprovalDetailView: View {
    let item: MobileApproval
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var confirm = false
    private var pending: Bool { store.approvals.contains { $0.id == item.id } }
    private var uncertain: Bool { store.uncertainApprovals.contains(item.id) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(item.request.title).font(.title2.bold())
                Text(store.profiles.first { $0.id == item.agentID }?.name ?? "Agent").foregroundStyle(.secondary)
                Text(item.request.command ?? "The server supplied no exact action. Approval is unavailable.")
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                if !pending { AvailabilityNote(text: "This request is no longer pending on this phone.") }
                if !item.request.canApprove { AvailabilityNote(text: "The exact action or approval choice is unavailable. This request cannot be approved here.") }
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Decline") { Task { await decide(false) } }.buttonStyle(.bordered).disabled(busy || uncertain || !pending || !item.request.choices.contains("deny"))
                    Button("Approve once") { confirm = true }.buttonStyle(.borderedProminent).disabled(busy || uncertain || !pending || !item.request.canApprove)
                }.controlSize(.large)
                if uncertain { Button("Check request status") { Task { do { try await store.checkApproval(item); error = nil } catch { self.error = "Could not confirm this request. Check it on desktop." } } }.buttonStyle(.bordered) }
                if busy { ProgressView("Waiting for server acknowledgment…") }
                AvailabilityNote(text: "A timeout keeps this request unresolved. Check the server before attempting another decision.")
            }.padding(20)
        }.navigationTitle("Review request").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Approve this exact action once?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Approve once") { Task { await decide(true) } }
                Button("Cancel", role: .cancel) {}
            }
    }
    private func decide(_ approved: Bool) async {
        busy = true; error = nil; defer { busy = false }
        do { try await store.resolve(item, approved: approved); dismiss() }
        catch { self.error = (error as? CoreError)?.localizedDescription ?? "The server did not confirm this decision. Check its state before retrying." }
    }
}
