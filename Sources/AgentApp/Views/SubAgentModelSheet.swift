import SwiftUI

/// P31 D: Manage bots → "Change sub-agent model…" and the Overview's Sub-agents "Change…". The "Change model…" request
/// with the role fixed to sub-agents: model (this bot's catalog), provider, which bots, or "Same as each bot's model"
/// (clears the pin). "Ask <manager>" sends the P30 recipe with `KM=delegation.model KP=delegation.provider` into the
/// manager's chat, where the manager asks Konrad first.
struct SubAgentModelSheet: View {
    enum Scope: Hashable { case this, some, all }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: SubAgentModelRequest
    @State private var scope: Scope
    @State private var picked: Set<String>
    @State private var model = ""
    @State private var provider = ""
    @State private var sameAsEachBot = false

    init(request: SubAgentModelRequest) {
        self.request = request
        _scope = State(initialValue: request.profile == nil ? .all : .this)
        _picked = State(initialValue: Set(request.profile.map { [$0] } ?? []))
    }

    private var manager: Bot? { store.bots.first { $0.id == request.managerID } }

    /// Profiles on the manager's box: what the last `models` report listed and the bots SwarmHub has there.
    private var profiles: [String] {
        guard let manager else { return [] }
        let target = store.connection(of: manager)
        let reported = store.boxReadings(on: target).models?.map(\.name) ?? []
        return Array(Set(reported).union(store.boundProfiles(on: target))).sorted()
    }

    /// The bot whose catalog feeds the model menu: the prefilled one, else the manager.
    private var catalogBot: Bot? {
        guard let manager else { return nil }
        let target = store.connection(of: manager)
        return request.profile.flatMap { profile in
            store.bots.first { $0.backend == .hermes && ($0.hermesProfile ?? "default") == profile && store.connection(of: $0) == target }
        } ?? manager
    }

    var change: SubAgentModelChange {
        let bots: SubAgentModelChange.Bots = switch scope {
        case .this: .some(request.profile.map { [$0] } ?? [])
        case .some: .some(profiles.filter(picked.contains))
        case .all: .all
        }
        if sameAsEachBot { return .clear(bots) }
        return SubAgentModelChange(model: model.trimmingCharacters(in: .whitespaces), provider: provider.trimmingCharacters(in: .whitespaces), bots: bots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change sub-agent model").font(.title3.weight(.semibold))
            Text(BoxReadingsCopy.modelsHelp).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Toggle(BoxReadingsCopy.sameAsEachBot, isOn: $sameAsEachBot)
                HStack {
                    TextField("Model", text: $model, prompt: Text("model id"))
                    RoleModelMenu(label: "From the list", leading: [], picker: catalogBot.map { store.modelPicker(for: $0) }) { setting in
                        if case .choice(let choice) = setting { model = choice.model; provider = choice.provider }
                    }
                }
                .disabled(sameAsEachBot)
                TextField("Provider", text: $provider, prompt: Text("provider id")).disabled(sameAsEachBot)
                Picker("Bots", selection: $scope) {
                    if let profile = request.profile { Text("This one (\(profile))").tag(Scope.this) }
                    Text("Some").tag(Scope.some)
                    Text("All bots on this box").tag(Scope.all)
                }
                if scope == .some {
                    ForEach(profiles, id: \.self) { profile in
                        Toggle(profile, isOn: Binding(get: { picked.contains(profile) }, set: { if $0 { picked.insert(profile) } else { picked.remove(profile) } }))
                    }
                }
            }
            .formStyle(.grouped)
            if !sameAsEachBot, !model.isEmpty, !change.isValid {
                Text("Use the model and provider ids exactly as the list shows them, both filled in.").font(.caption).foregroundStyle(.orange)
            }
            Text("\(manager?.name ?? "The manager") asks you in its chat before it changes anything.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ask \(manager?.name ?? "the manager")") {
                    if let manager, store.requestSubAgentModel(change, manager: manager) { dismiss() }
                }
                .keyboardShortcut(.defaultAction).disabled(manager == nil || !change.isValid || !store.isIdle)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: prefill)
    }

    /// The prefilled bot's reported pin, else its own provider.
    private func prefill() {
        guard let manager, let profile = request.profile,
              let row = store.boxReadings(on: store.connection(of: manager)).models(for: profile) else { return }
        model = row.subModel; provider = row.subModel.isEmpty ? row.provider : row.subProvider
    }
}
