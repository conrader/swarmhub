import AppKit
import SwiftUI

/// The setup window (P21 Part C), its own scene so Settings, the quick switcher, the empty state and the banners can
/// all open it. Back and Cancel on every step, "Skip for now" on the first; closing the window counts as Cancel.
/// Only S4's Add writes (`AppStore.commitSetup`), and Hermes' Test runs in memory. OpenClaw's Test saves the Gateway it
/// connects through (P25 D4); Cancel, Back to the software choice or closing the window forgets it again.
struct SetupView: View {
    static let windowID = "setup"
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var flow = SetupFlow()
    @State private var testing = false
    @State private var failure: String?
    @State private var closed = false
    /// `--render-setup`: start on this state instead of the store's prefill.
    var preset: SetupFlow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch flow.step {
                case .welcome: SetupWelcomeStep(flow: $flow, samples: samples)
                case .hosting: SetupHostingStep(flow: $flow)
                case .software: SetupSoftwareStep(flow: $flow)
                case .address: SetupAddressStep(flow: $flow, testing: testing, test: test)
                case .openClaw: SetupOpenClawStep(flow: $flow, testing: testing, test: testOpenClaw)
                case .openClaw:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(testing ? SetupCopy.testing : flow.awaitsPairing ? SetupCopy.testAgain : SetupCopy.test, action: testOpenClaw).buttonStyle(.borderedProminent)
                    .disabled(testing || flow.openClaw.problem != nil).keyboardShortcut(.defaultAction)
            case .choose: SetupChooseStep(flow: $flow, added: added)
                case .done: SetupDoneStep(flow: flow, agentName: store.selectedBot?.name)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24) }
            Divider()
            footer.padding(16)
        }
        .frame(width: 580, height: 480).background(AppColor.panel)
        .onAppear(perform: restart).onChange(of: store.setupGeneration) { _, _ in restart() }
        .onAppear { closed = false }
        .onDisappear { closed = true; FirstRun.dismissed(store.defaults); abandonGateway() }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if flow.canGoBack { Button(SetupCopy.back, action: back) }
            Spacer()
            switch flow.step {
            case .welcome:
                Button(SetupCopy.skip) { FirstRun.record(.skipped, in: store.defaults); dismiss() }
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
            case .hosting:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(SetupCopy.connectCardTitle) { flow.apply(.connectExisting) }.buttonStyle(.borderedProminent)
            case .software:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
            case .address:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(testing ? SetupCopy.testing : SetupCopy.test, action: test).buttonStyle(.borderedProminent)
                    .disabled(testing || flow.input.address.trimmingCharacters(in: .whitespaces).isEmpty).keyboardShortcut(.defaultAction)
            case .openClaw:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(testing ? SetupCopy.testing : flow.awaitsPairing ? SetupCopy.testAgain : SetupCopy.test, action: testOpenClaw).buttonStyle(.borderedProminent)
                    .disabled(testing || flow.openClaw.problem != nil).keyboardShortcut(.defaultAction)
            case .choose:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(SetupCopy.addButton(flow.chosen.count), action: add).buttonStyle(.borderedProminent).disabled(!flow.canAdd).keyboardShortcut(.defaultAction)
            case .done:
                if let name = store.selectedBot?.name {
                    Button(SetupCopy.openAgent(name), action: openFirst).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(SetupCopy.close) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// S4's already-added ids for the software chosen.
    private var added: Set<String> { flow.software == .openClaw ? store.openClawAgentIDs(boundTo: flow.openClawGatewayID) : store.addedProfileIDs }

    private func restart() { abandonGateway(); flow = preset ?? SetupFlow(prefill: store.setupPrefill); testing = false; failure = nil }

    private func cancel() { FirstRun.dismissed(store.defaults); abandonGateway(); dismiss() }

    private func back() {
        failure = nil; flow.apply(.back)
        if flow.step == .software || flow.step == .welcome { abandonGateway() }
    }

    /// Forgets the Gateway this run saved at Test (never one that existed before; a no-op after Add kept it).
    private func abandonGateway() { Task { await store.abandonSetupGateway() } }

    private func testOpenClaw() {
        guard flow.openClaw.problem == nil, !testing else { return }
        let draft = flow.openClaw
        testing = true; failure = nil
        Task {
            let tested = await store.testSetupGateway(draft)
            if closed { await store.abandonSetupGateway(); return }
            flow.apply(.openClawTest(tested.outcome, gatewayID: tested.gatewayID))
            if case .connected = tested.outcome { flow.preselect(alreadyAdded: added) }
            testing = false
        }
    }

    private func samples() { store.loadSamples(); FirstRun.dismissed(store.defaults); showMainWindow(); dismiss() }

    private func test() {
        let input = flow.input, keyStore = store.keyStore, keepSaved = flow.prefill.address != nil
        testing = true; failure = nil
        Task {
            let result = await SetupCheck.run(input, savedKey: { keepSaved ? keyStore.key(for: "hermes") : "" }, session: store.hermesSession)
            flow.apply(.test(result))
            if result.succeeded { flow.preselect(alreadyAdded: store.addedProfileIDs) }
            testing = false
        }
    }

    private func add() {
        do {
            let added: [Bot]
            if flow.software == .openClaw {
                added = try store.commitSetupOpenClaw(gatewayID: flow.openClawGatewayID, agents: flow.openClawAgents, chosen: flow.chosen)
            } else {
                guard let result = flow.result else { return }
                added = try store.commitSetup(result, key: flow.input.key, chosen: flow.chosen, confirmMove: flow.confirmMove)
            }
            flow.apply(.add(count: added.count, first: store.selectedBot?.name))
        } catch { failure = SetupCopy.failed }
    }

    private func openFirst() {
        if let bot = store.selectedBot { store.open(bot) }
        showMainWindow(); dismiss()
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == AppConstants.name }) { window.makeKeyAndOrderFront(nil) } else { openWindow(id: ContentView.windowID) }
    }
}
