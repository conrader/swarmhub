import Foundation
import Observation
import SwarmHubCore

/// Device-signed managed approvals (P5d). Only boxes whose device-required cutover was confirmed on this phone get
/// cards; every other box shows none. Decisions are Ed25519-signed with this phone's own approval key, never with the
/// Hermes key. Native Hermes approvals stay in MobileStore, unchanged.
@MainActor @Observable
final class ManagedApprovalStore {
    enum State: Equatable {
        case pending(ManagedRecord)
        /// An earlier signed attempt may have committed; only a box receipt can resolve it.
        case awaitingReceipt(approved: Bool?)
        case failed(String)
    }
    struct Card: Identifiable, Equatable {
        let target: ManagedApprovalTarget
        var state: State
        var id: String { target.origin + " " + target.task }
    }

    var cards: [Card] = []
    var deciding: Set<String> = []
    var refreshing = false
    var notice: String?
    /// Bumped on a confirmed cutover, so views that read device-required routing (stored in UserDefaults) update.
    private(set) var routingRevision = 0
    @ObservationIgnored let settings: DeviceApprovalSettings
    @ObservationIgnored private let keys: any DeviceApprovalKeyStore
    @ObservationIgnored private let session: URLSession?

    init(defaults: UserDefaults = .standard, keys: any DeviceApprovalKeyStore = DeviceApprovalKeychain(), session: URLSession? = nil) {
        settings = DeviceApprovalSettings(defaults: defaults); self.keys = keys; self.session = session
    }

    func requiredOrigins(_ profiles: [AgentProfile]) -> [String] {
        _ = routingRevision
        return ManagedApprovalScope.requiredOrigins(profiles, settings: settings)
    }

    func identity(origin: String) throws -> DeviceApprovalIdentity {
        try DeviceApprovalIdentity.loadOrCreate(box: origin, store: keys, prefix: DeviceApprovalIdentity.iosKeyPrefix)
    }

    /// Local routing only, after the operator ran `swarm_devices.py mode required` on the box. Sticky by design.
    func confirmCutover(_ origin: String) { settings.confirmOperatorCutover(origin); routingRevision += 1 }

    /// Reads every notified task on device-required boxes. A notice is only a hint: a card appears only for a
    /// pending record the box returns, and a committed receipt removes it.
    func refresh(profiles: [AgentProfile], caches: [String: ChatCache], demo: Bool) async {
        guard !refreshing else { return }
        guard !demo else { cards = []; return }
        refreshing = true; defer { refreshing = false }
        let targets = ManagedApprovalScope.targets(profiles: profiles, caches: caches, settings: settings)
        cards.removeAll { card in !deciding.contains(card.id) && !targets.contains(card.target) }
        for target in targets where !deciding.contains(target.origin + " " + target.task) { await load(target) }
    }

    func check(_ card: Card) async { await load(card.target) }

    func hide(_ card: Card) { if !deciding.contains(card.id) { cards.removeAll { $0.id == card.id } } }

    private func load(_ target: ManagedApprovalTarget) async {
        let id = target.origin + " " + target.task
        let shown = cards.contains { $0.id == id }
        do {
            let record = try await ManagedApprovalFlow.load(target, identity: identity(origin: target.origin), settings: settings, session: session)
            if record.remoteReceipt != nil || !record.awaiting {
                if shown { notice = receiptNotice(record, approved: nil) }
                cards.removeAll { $0.id == id }
            } else if let index = cards.firstIndex(where: { $0.id == id }) {
                // A refresh never replaces a reviewed record with a different operation.
                if case .pending(let reviewed) = cards[index].state, !record.sameOperation(as: reviewed) {
                    cards[index].state = .failed(ManagedControlError.invalidRecord.localizedDescription)
                } else { cards[index].state = .pending(record) }
            } else { cards.append(Card(target: target, state: .pending(record))) }
        } catch {
            fail(target, error, shown: shown)
        }
    }

    func decide(_ card: Card, approved: Bool) async {
        guard case .pending(let reviewed) = card.state, !deciding.contains(card.id) else { return }
        if let earlier = attemptChoice(card.target), earlier != approved {
            notice = "The earlier decision is still awaiting a receipt. Check its status first."; return
        }
        deciding.insert(card.id); defer { deciding.remove(card.id) }
        do {
            let receipt = try await ManagedApprovalFlow.decide(card.target, reviewed: reviewed, approved: approved,
                                                               identity: identity(origin: card.target.origin), settings: settings, session: session)
            cards.removeAll { $0.id == card.id }
            notice = receiptNotice(receipt, approved: approved)
        } catch {
            fail(card.target, error, shown: true)
        }
    }

    private func fail(_ target: ManagedApprovalTarget, _ error: Error, shown: Bool) {
        let id = target.origin + " " + target.task
        let message = error.localizedDescription
        if let control = error as? ManagedControlError {
            switch control {
            case .operationGone:
                if shown { notice = message }
                cards.removeAll { $0.id == id }
                return
            case .attemptExpired, .refused, .unsent:
                // Nothing was recorded. A reviewed card stays and the user chooses again; any other card
                // (for example one restored from a saved attempt) asks for a fresh status check first.
                if let index = cards.firstIndex(where: { $0.id == id }), case .pending = cards[index].state { notice = message }
                else { upsert(target, .failed(message)) }
                return
            default: break
            }
        }
        if settings.hasAttempt(origin: target.origin, task: target.task) {
            upsert(target, .awaitingReceipt(approved: attemptChoice(target)))
        } else if shown {
            // Keep a reviewed card; only its status is unknown. Unknown tasks from old messages stay hidden.
            if let index = cards.firstIndex(where: { $0.id == id }), case .pending = cards[index].state { notice = message }
            else { upsert(target, .failed(message)) }
        }
    }

    private func upsert(_ target: ManagedApprovalTarget, _ state: State) {
        let id = target.origin + " " + target.task
        if let index = cards.firstIndex(where: { $0.id == id }) { cards[index].state = state }
        else { cards.append(Card(target: target, state: state)) }
    }

    private func attemptChoice(_ target: ManagedApprovalTarget) -> Bool? {
        (try? settings.attempt(origin: target.origin, task: target.task))?["approved"]?.boolValue
    }

    private func receiptNotice(_ record: ManagedRecord, approved: Bool?) -> String {
        guard let recorded = record.remoteReceipt?.approved else { return "This operation is no longer pending on the box." }
        let text = recorded ? "The box recorded the approval." : "The box recorded the denial."
        return approved == nil || approved == recorded ? text : "The box had already recorded another decision. " + text
    }
}
