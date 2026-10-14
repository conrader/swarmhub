import SwiftUI

/// The setup window's steps (P21 item 11); every visible string comes from `SetupCopy` / `ManagedHosting`.
struct SetupWelcomeStep: View {
    @Binding var flow: SetupFlow
    let samples: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SetupCopy.welcomeTitle).font(.title2.bold())
            SetupCard(title: SetupCopy.connectCardTitle, lines: [SetupCopy.connectCardDetail, SetupCopy.softwareLine], badge: nil) { flow.apply(.connectExisting) }
            SetupCard(title: ManagedHosting.cardTitle, lines: [ManagedHosting.cardDetail], badge: ManagedHosting.badge) { flow.apply(.newHosted) }
            Button(SetupCopy.sampleLink, action: samples).buttonStyle(.link)
        }
    }
}

/// One clickable card: a title, plain lines and an optional badge.
struct SetupCard: View {
    let title: String; let lines: [String]; let badge: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    ForEach(lines, id: \.self) { line in Text(line).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                if let badge { Text(badge).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.1))) }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10)).contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
}

/// S-host: strictly inert; nothing here makes a request or stores anything (`ManagedHosting`).
struct SetupHostingStep: View {
    @Binding var flow: SetupFlow
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ManagedHosting.title).font(.title2.bold())
            Text(ManagedHosting.detail).foregroundStyle(.secondary)
        }
    }
}

/// S3: address, key and the folded extra agents. Nothing is saved here.
struct SetupAddressStep: View {
    @Binding var flow: SetupFlow
    let testing: Bool
    let test: () -> Void
    @State private var showMore = false
    var body: some View {
        Form {
            Section {
                TextField(SetupCopy.addressLabel, text: $flow.input.address, prompt: Text(SetupCopy.addressPlaceholder)).onSubmit(test)
                SecureField(SetupCopy.keyLabel, text: $flow.input.key).onSubmit(test)
                Text(flow.prefill.address == nil ? SetupCopy.keyCaption : SetupCopy.keepKeyCaption).font(.caption).foregroundStyle(.secondary)
                Text(SetupCopy.helpLine).font(.caption).foregroundStyle(.secondary)
            } header: { Text(SetupCopy.addressTitle) }
            Section {
                DisclosureGroup(isExpanded: Binding(get: { showMore || !flow.input.extra.isEmpty }, set: { showMore = $0 })) {
                    TextEditor(text: $flow.input.extra).font(.body.monospaced()).frame(height: 70)
                    Text(SetupCopy.moreAgentsCaption).font(.caption).foregroundStyle(.secondary)
                    Text(SetupCopy.moreAgentsExample).font(.caption.monospaced()).foregroundStyle(.secondary)
                } label: { Text(SetupCopy.moreAgents) }
            }
            if let result = flow.result, !result.succeeded, !testing {
                Text(result.message).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(-20)
    }
}

/// S4: one tick per agent the test found; agents already on this app are shown, disabled.
struct SetupChooseStep: View {
    @Binding var flow: SetupFlow
    let added: Set<String>
    var body: some View {
        Form {
            Section {
                ForEach(flow.result?.available ?? [], id: \.id) { agent in
                    let present = added.contains(agent.id)
                    Toggle(isOn: Binding(get: { present || flow.chosen.contains(agent.id) }, set: { on in
                        if on { flow.chosen.insert(agent.id) } else { flow.chosen.remove(agent.id) }
                    })) {
                        HStack { Text(agent.name); if present { Text(SetupCopy.alreadyAdded).font(.caption).foregroundStyle(.secondary) } }
                    }.disabled(present)
                }
                ForEach(flow.result?.problems ?? [], id: \.self) { line in Text(line).font(.caption).foregroundStyle(.orange) }
            } header: { Text(SetupCopy.chooseTitle) } footer: { Text(flow.result?.message ?? "").font(.caption) }
            if flow.movesAddress { Section { Toggle(SetupCopy.moveConfirm, isOn: $flow.confirmMove) } }
            Text(SetupCopy.addLater).font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).scrollContentBackground(.hidden).padding(-20)
    }
}

/// S5: connected; the footer opens the first added agent.
struct SetupDoneStep: View {
    let flow: SetupFlow
    let agentName: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(SetupCopy.doneTitle(flow.addedCount)).font(.title2.bold())
            Text(SetupCopy.addLater).foregroundStyle(.secondary)
        }
    }
}
