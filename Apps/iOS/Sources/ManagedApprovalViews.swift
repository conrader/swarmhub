import SwiftUI
import SwarmHubCore

/// Managed approvals on device-required boxes only. Renders nothing at all unless a connected, opted-in box reported
/// device-required mode on its latest read, so legacy (or unknown) boxes never show a managed card or a way to decide
/// one from this phone. The refresh that asks the boxes runs from ApprovalsView, so it also runs while this is hidden.
struct ManagedApprovalsSection: View {
    @Environment(MobileStore.self) private var store
    @Environment(ManagedApprovalStore.self) private var managed
    var body: some View {
        if !store.demo, !managed.requiredOrigins(store.profiles).isEmpty {
            Section {
                if managed.cards.isEmpty {
                    Text(managed.refreshing ? "Checking device-required boxes…" : "No managed operations are waiting on your device-required boxes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(managed.cards) { card in
                    NavigationLink { ManagedApprovalDetailView(cardID: card.id) } label: { ManagedApprovalRow(card: card) }
                }
                Button("Check device-required boxes", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    .disabled(managed.refreshing)
                if let notice = managed.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("Managed operations") } footer: {
                Text("Signed with this phone’s approval key and sent directly to the box. Only boxes switched to device-required mode appear here.")
            }
        } else if !store.demo, let notice = managed.notice {
            Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func refresh() async { await managed.refresh(profiles: store.profiles, caches: store.caches, demo: store.demo) }
}

private struct ManagedApprovalRow: View {
    let card: ManagedApprovalStore.Card
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.target.origin).font(.caption).foregroundStyle(.secondary)
            switch card.state {
            case .pending(let record):
                Text("\(record.spec.kind.capitalized) action awaits the \(record.gate)").font(.headline)
                Text(record.spec.intent).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            case .awaitingReceipt:
                Text("Decision awaiting the box’s receipt").font(.headline)
            case .failed:
                Text("Status unconfirmed").font(.headline)
            }
            Text(card.target.task).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 6)
    }
}

struct ManagedApprovalDetailView: View {
    let cardID: String
    @Environment(ManagedApprovalStore.self) private var managed
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    private var card: ManagedApprovalStore.Card? { managed.cards.first { $0.id == cardID } }
    private var busy: Bool { managed.deciding.contains(cardID) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let card {
                    Text(card.target.origin).foregroundStyle(.secondary)
                    switch card.state {
                    case .pending(let record): pending(card, record)
                    case .awaitingReceipt(let approved):
                        AvailabilityNote(text: "An earlier \(approved == false ? "denial" : approved == true ? "approval" : "decision") was sent and may have been recorded. Only the box’s receipt can settle it; nothing is resent.")
                        check(card)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                        check(card)
                        Button("Hide from this phone") { managed.hide(card); dismiss() }.buttonStyle(.bordered)
                    }
                    if busy { ProgressView("Waiting for the box’s receipt…") }
                } else {
                    AvailabilityNote(text: "This operation is no longer pending on this phone.")
                }
                if let notice = managed.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
            }.padding(20)
        }.navigationTitle("Managed operation").navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func pending(_ card: ManagedApprovalStore.Card, _ record: ManagedRecord) -> some View {
        Text("\(record.spec.kind.capitalized) action awaits the \(record.gate)").font(.title2.bold())
        LabeledContent("Decider profile", value: record.decider ?? card.target.profile)
        LabeledContent("Submitted by", value: record.spec.bot)
        if let risks = record.spec.risks, !risks.isEmpty { LabeledContent("Risks", value: risks.joined(separator: ", ")) }
        // The complete stored operation, exactly as the box fingerprints it.
        let shown = operation(record)
        Text(shown ?? "The operation could not be displayed, so it cannot be approved here.").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
            .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        Text("Fingerprint \(record.fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        HStack {
            Button("Deny") { Task { await managed.decide(card, approved: false) } }.buttonStyle(.bordered)
            Button("Approve once") { confirm = true }.buttonStyle(.borderedProminent).disabled(shown == nil)
        }.controlSize(.large).disabled(busy)
            .confirmationDialog("Approve this exact operation once?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Approve once") { Task { await managed.decide(card, approved: true) } }
                Button("Cancel", role: .cancel) {}
            }
        AvailabilityNote(text: "A timeout keeps this operation locked until the box reports a receipt. Nothing is resent automatically.")
    }

    private func check(_ card: ManagedApprovalStore.Card) -> some View {
        Button("Check status with the box") { Task { await managed.check(card) } }.buttonStyle(.bordered).disabled(busy)
    }

    private func operation(_ record: ManagedRecord) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? encoder.encode(record.spec.fields)).map { String(decoding: $0, as: UTF8.self) }
    }
}
