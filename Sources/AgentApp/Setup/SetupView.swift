import AppKit
import SwiftUI

/// The setup window (P21 Part C), its own scene so Settings, the quick switcher, the empty state and the banners can
/// all open it. Back and Cancel on every step, "Skip for now" on the first; closing the window counts as Cancel.
/// Only S4's Add writes (`AppStore.commitSetup`), and Hermes' Test runs in memory. OpenClaw's Test saves the Gateway it
/// connects through (P25 D4); Cancel, Back to the software choice or closing the window forgets it again.
///
/// With the older backends hidden (the default) the window is the Herdr wizard: where bots run, Connect, the main bot
/// and the optional bots. Return goes on when the step is complete, Escape closes, and only the last button writes
/// (`AppStore.commitSetupWizard`): it then closes the window on the main bot's chat, with the keyboard in its composer.
struct SetupView: View {
    static let windowID = "setup"
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var flow = SetupFlow()
    @State private var testing = false
    @State private var failure: String?
    @State private var closed = false
    /// The wizard's last button was pressed and its bots exist: Return in a field and the default button may both ask.
    @State private var finished = false
    /// Off (the default): the window offers Herdr only (`LegacySurface`).
    @AppStorage(LegacySurface.key) private var legacy = false
    /// `--render-setup`: start on this state instead of the store's prefill; `presetTesting` shows it with a Test running.
    var preset: SetupFlow?
    var presetTesting = false

    /// The size of the window, and of every render of it.
    static let size = CGSize(width: 580, height: 520)

    /// Which of the wizard's four steps is showing; nil on the older paths' screens.
    private var wizardStep: Int? {
        switch flow.step {
        case .welcome: legacy ? nil : 0
        case .herdr: 1
        case .mainBot: 2
        case .moreBots: 3
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let wizardStep {
                // The optional bots are no step on a server whose only agent program the main bot already has.
                SetupWizardProgress(current: wizardStep, count: flow.step == .mainBot && flow.herdrOffer != nil && flow.moreChoices.isEmpty ? 3 : 4).padding(.horizontal, 24).padding(.top, 18)
            }
            Group {
                switch flow.step {
                case .welcome:
                    if legacy { SetupWelcomeStep(flow: $flow, samples: samples) } else { SetupHerdrWelcomeStep(flow: $flow, advance: pickPlace) }
                case .hosting: SetupHostingStep(flow: $flow)
                case .software: SetupSoftwareStep(flow: $flow)
                case .address: SetupAddressStep(flow: $flow, testing: testing, test: test)
                case .openClaw: SetupOpenClawStep(flow: $flow, testing: testing, test: testOpenClaw)
                case .herdr: SetupHerdrStep(flow: $flow, testing: testing, test: testHerdr)
                case .mainBot: SetupMainBotStep(flow: $flow, submit: leaveMainBot)
                case .moreBots: SetupMoreBotsStep(flow: $flow)
                case .choose: SetupChooseStep(flow: $flow, added: added)
                case .done: SetupDoneStep(flow: flow, agentName: store.selectedBot?.name)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24).padding(.top, wizardStep == nil ? 0 : -6)
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 24) }
            Divider()
            footer.padding(16)
        }
        .frame(width: Self.size.width, height: Self.size.height).background(AppColor.panel)
        .onAppear(perform: restart).onChange(of: store.setupGeneration) { _, _ in restart() }
        .onAppear { closed = false }
        .onDisappear { closed = true; FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)); abandonGateway(); abandonHerdr() }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if flow.canGoBack { Button(SetupCopy.back, action: back) }
            Spacer()
            switch flow.step {
            case .welcome:
                if legacy { Button(SetupCopy.skip) { FirstRun.record(.skipped, in: store.defaults); dismiss() } }
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                if !legacy { Button(WizardCopy.next, action: pickPlace).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
            case .hosting:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                if legacy { Button(SetupCopy.connectCardTitle) { flow.apply(.connectExisting) }.buttonStyle(.borderedProminent) }
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
            case .herdr:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                if flow.herdrReady, !testing {
                    Button(WizardCopy.next) { failure = nil; flow.apply(.advance) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(testing ? SetupCopy.testing : flow.herdrOutcome != nil ? SetupCopy.testAgain : SetupCopy.test, action: testHerdr).buttonStyle(.borderedProminent)
                        .disabled(testing || flow.herdr.problem != nil).keyboardShortcut(.defaultAction)
                }
            case .mainBot:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(flow.isLastWizardStep && flow.herdrOffer != nil ? finishTitle : WizardCopy.next, action: leaveMainBot).buttonStyle(.borderedProminent)
                    .disabled(!flow.mainBotReady).keyboardShortcut(.defaultAction)
            case .moreBots:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(finishTitle, action: finishWizard).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .choose:
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(addTitle, action: add).buttonStyle(.borderedProminent).disabled(!flow.canAdd).keyboardShortcut(.defaultAction)
            case .done:
                if let name = store.selectedBot?.name {
                    Button(SetupCopy.openAgent(name), action: openFirst).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                } else {
                    Button(SetupCopy.close) { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// The wizard's last button says what it creates: the main bot alone, the main bot and the ticked ones, or (with
    /// a main bot that stays) only the ticked ones.
    private var finishTitle: String {
        let more = flow.step == .moreBots ? flow.moreChosen.count : 0
        if flow.keptMainBot != nil { return more == 0 ? WizardCopy.finish : WizardCopy.addBots(more) }
        return more == 0 ? (flow.mainBotName.isEmpty ? WizardCopy.createMain : WizardCopy.create(flow.mainBotName)) : WizardCopy.createBots(more + 1)
    }

    /// P35: with the batch on, Add counts the bots it connects too.
    private var addTitle: String {
        guard let scan = flow.boxScan, flow.adoptOn, !scan.adoptable.isEmpty else { return SetupCopy.addButton(flow.chosen.count) }
        return BoxCopy.addButton(flow.chosen.count + scan.adoptable.count)
    }

    /// S4's already-added ids for the software chosen.
    private var added: Set<String> {
        flow.software == .openClaw ? store.openClawAgentIDs(boundTo: flow.openClawGatewayID) : store.addedProfileIDs
    }

    /// The saved address and a history-only agent's line prefill the Hermes path only. The wizard opens where
    /// `AppStore.wizardStart` says; on the main bot of a server that is already set up it reads that server at once.
    private func restart() {
        abandonGateway(); abandonHerdr()
        flow = preset ?? (legacy ? SetupFlow(prefill: store.setupPrefill) : store.wizardStart()); testing = presetTesting; failure = nil; finished = false
        if preset == nil, flow.readsSavedServer { testHerdr() }
    }

    private func cancel() { FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)); abandonGateway(); abandonHerdr(); dismiss() }

    private func back() {
        failure = nil
        let tested = flow.herdrServer
        flow.apply(.back)
        if flow.step == .software || flow.step == .welcome { abandonGateway(); store.abandonSetupHerdr(tested) }
    }

    /// Closes the forward Herdr's Test opened, unless Add saved its server.
    private func abandonHerdr() { store.abandonSetupHerdr(flow.herdrServer) }

    /// Welcome's Continue. "This Mac" needs nothing typed, so it looks for Herdr at once.
    private func pickPlace() {
        guard flow.step == .welcome else { return }
        failure = nil; flow.apply(.pickHerdr(flow.place))
        if flow.place == .local { testHerdr() }
    }

    /// Connect's Test, and the reading of a server that was set up before (the window then waits on the main bot).
    private func testHerdr() {
        guard flow.herdr.problem == nil, !testing else { return }
        let draft = flow.herdr, step = flow.step
        testing = true; failure = nil
        Task {
            let outcome = await store.testSetupHerdr(draft)
            testing = false
            let current = !closed && flow.step == step && flow.herdr == draft
            guard case .connected(let server, _, _) = outcome else { if current { flow.apply(.herdrTest(outcome)) }; return }
            guard current else { store.abandonSetupHerdr(server); return }
            flow.apply(.herdrTest(outcome, bots: store.setupHerdrBots(on: server)))
        }
    }

    /// The main bot's button, and Return in its name: on to the optional bots, or straight to the end when the
    /// server has no other agent program to offer.
    private func leaveMainBot() {
        guard flow.step == .mainBot, flow.mainBotReady else { return }
        failure = nil
        if flow.isLastWizardStep { finishWizard() } else { flow.apply(.advance) }
    }

    /// The wizard's one write: the server, the main bot and the ticked bots. Then the main window shows the main
    /// bot's chat with the keyboard in its composer.
    private func finishWizard() {
        guard flow.isLastWizardStep, flow.mainBotReady, !finished else { return }
        do {
            let main = try store.commitSetupWizard(server: flow.herdrServer, key: flow.herdrKey, main: flow.mainBot,
                                                   more: flow.step == .moreBots ? flow.moreChosen : [], offer: flow.herdrOffer)
            finished = true
            store.open(main); store.composerFocus = main.id
            showMainWindow(); dismiss()
        } catch { failure = SetupCopy.failed }
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
            // P35: then the box's other bots, quietly; S4 already shows what Test found.
            guard result.succeeded else { return }
            let scan = await store.scanBoxForSetup(result, key: input.key)
            if !closed, flow.result == result { flow.apply(.boxScanned(scan)) }
        }
    }

    private func add() {
        do {
            let added: [Bot]
            if flow.software == .openClaw {
                added = try store.commitSetupOpenClaw(gatewayID: flow.openClawGatewayID, agents: flow.openClawAgents, chosen: flow.chosen)
            } else {
                guard let result = flow.result else { return }
                added = try store.commitSetup(result, key: flow.input.key, chosen: flow.chosen, confirmMove: flow.confirmMove, scan: flow.boxScan)
            }
            flow.apply(.add(count: added.count, first: store.selectedBot?.name))
            // P35: Add is the yes for the listed batch; the manager connects them in its chat.
            if let scan = flow.boxScan, flow.adoptOn, !scan.adoptable.isEmpty, let manager = store.bots.first(where: {
                store.isManager($0) && $0.backend == .hermes && ($0.hermesProfile ?? "default") == scan.managerProfile }),
               store.startAdoption(scan.adoptable, manager: manager) {
                flow.adopting = scan.adoptable
            }
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
