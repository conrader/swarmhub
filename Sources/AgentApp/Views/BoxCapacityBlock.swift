import SwiftUI

/// P31 E: Settings → Models, under Coding agent, for one Hermes connection: "This box: 2 CPUs, 3.8 GB — 1 coding job
/// at a time (set by you | advised)", the advice line, when it was checked, and Check / Use advised / Set limit….
/// Check is a quiet manager turn; a limit is asked in the manager's chat, where the manager asks Konrad first.
struct BoxCapacityBlock: View {
    @EnvironmentObject private var store: AppStore
    let target: String
    let host: String
    @State private var settingLimit = false
    @State private var limit = 1

    var body: some View {
        let readings = store.boxReadings(on: target)
        let capacity = readings.capacity.map(BoxCapacity.init)
        let checking = store.boxChecks.contains(.capacity(target))
        VStack(alignment: .leading, spacing: 4) {
            Text(host).font(.caption2).foregroundStyle(.tertiary)
            Text(capacity?.line ?? BoxReadingsCopy.capacityMissing)
            if let capacity {
                if let advice = capacity.advice(now: store.now()) { Text(advice).font(.caption).foregroundStyle(.orange) }
                if let note = capacity.notApplied { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            if let problem = store.boxCheckProblems[.capacity(target)] { Text(problem).font(.caption).foregroundStyle(.orange) }
            HStack {
                if let at = readings.capacityAt { Text(BoxReadingsCopy.checked(at)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Check") { Task { await store.checkCapacity(on: target) } }.disabled(checking)
                if let capacity, capacity.offersAdvised {
                    Button("Use advised") { store.requestCodingLimit(capacity.advised, on: target) }.disabled(!store.managerIdle(on: target))
                }
                Button("Set limit…") { limit = capacity?.slots ?? 1; settingLimit = true }.disabled(capacity == nil)
                    .popover(isPresented: $settingLimit) { if let capacity { limitPopover(capacity) } }
            }
        }
    }

    private func limitPopover(_ capacity: BoxCapacity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("\(limit) coding \(limit == 1 ? "job" : "jobs") at a time", value: $limit, in: capacity.limitRange)
            Text("Advised: \(capacity.advised). Running jobs keep going; the next job uses the new limit.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { settingLimit = false }
                Button("Ask the manager") { if store.requestCodingLimit(limit, on: target) { settingLimit = false } }
                    .keyboardShortcut(.defaultAction).disabled(!store.managerIdle(on: target))
            }
        }
        .padding(16).frame(width: 340)
    }
}
