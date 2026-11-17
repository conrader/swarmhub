import AppKit
import SwiftUI

/// The setup window, its own scene so Settings, the quick switcher and the empty state can all open it. It is a
/// wizard: where bots run, Connect, the main bot and the optional bots. Back and Cancel on every step; closing the
/// window counts as Cancel. Return goes on when the step is complete, Escape closes, and only the last button writes
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
    /// Nobody asked for this window in this run (`cameBackUnasked`): it closes itself and leaves the first-run state alone.
    @State private var unasked = false
    /// `--render-setup`: start on this state instead of the store's prefill; `presetTesting` shows it with a Test running.
    var preset: SetupFlow?
    var presetTesting = false
    /// The project servers of the server being set up, read with the access key Test used; a render passes a state in.
    @State private var projects: HerdrProjectsModel?
    var presetProjects: HerdrProjectsModel?
    /// A render of a step that scrolls can ask for a taller window, so all of the step is in the picture.
    var presetHeight: CGFloat?

    /// The size of the window, and of every render of it.
    static let size = CGSize(width: 620, height: 640)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    switch flow.step {
                    case .welcome: SetupHerdrWelcomeStep(flow: $flow, advance: pickPlace)
                    case .herdr: SetupHerdrStep(flow: $flow, testing: testing, test: testHerdr)
                    case .mainBot: SetupMainBotStep(flow: $flow, submit: leaveMainBot)
                    case .moreBots: SetupMoreBotsStep(flow: $flow)
                    case .projects: if let model = presetProjects ?? projects { SetupProjectsStep(flow: $flow, model: model) }
                    }
                }.frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 20)
            }.scrollBounceBehavior(.basedOnSize)
            if let failure { Text(failure).font(.callout).foregroundStyle(.orange).padding(.horizontal, 24).padding(.bottom, 8) }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: presetHeight ?? Self.size.height).background(AppColor.panel)
        .onAppear { if Self.cameBackUnasked(preset: preset, generation: store.setupGeneration) { closeUnasked() } else { restart() } }
        .onChange(of: store.setupGeneration) { _, _ in unasked = false; restart() }
        .onChange(of: flow.step, initial: true) { _, step in readProjects(step) }
        .onAppear { closed = false }
        .onDisappear { closed = true; if !unasked { FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)) }; abandonHerdr() }
    }

    /// macOS brings back the windows that were open when an app was killed or the Mac restarted. Every way to this
    /// window goes through `AppStore.openSetup`, which counts; a setup window that shows before anything asked for it
    /// in this run is such a returned one, and the wizard must not come back by itself on an install that is set up.
    static func cameBackUnasked(preset: SetupFlow?, generation: Int) -> Bool { preset == nil && generation == 0 }

    /// Closes the returned window a moment later, unless the launch has asked for the wizard meanwhile (a first run).
    private func closeUnasked() {
        unasked = true
        DispatchQueue.main.async {
            guard store.setupGeneration == 0 else { unasked = false; restart(); return }
            closeWindow()
        }
    }

    /// Closes this window: through SwiftUI, and directly when it is still there a moment later.
    private func closeWindow() {
        dismiss()
        DispatchQueue.main.async { NSApp?.windows.first { $0.isVisible && $0.title == SetupCopy.windowTitle }?.close() }
    }

    /// Back on the left, the step dots in the middle, Cancel and the default button (Return) on the right.
    private var footer: some View {
        ZStack {
            // The optional bots are no step on a server whose only agent program the main bot already has.
            SetupWizardProgress(current: flow.stepIndex, count: flow.stepCount, name: flow.step == .projects ? WizardCopy.projectsStep : nil)
            HStack(spacing: 10) {
                if flow.canGoBack { Button(SetupCopy.back, action: back) }
                Spacer()
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction)
                switch flow.step {
                case .welcome:
                    Button(WizardCopy.next, action: pickPlace).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .herdr:
                    if flow.herdrReady, !testing {
                        Button(WizardCopy.next) { failure = nil; flow.apply(.advance) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    } else {
                        Button(testing ? SetupCopy.testing : flow.herdrOutcome != nil ? SetupCopy.testAgain : SetupCopy.test, action: testHerdr).buttonStyle(.borderedProminent)
                            .disabled(testing || flow.herdr.problem != nil).keyboardShortcut(.defaultAction)
                    }
                case .mainBot:
                    Button(flow.isLastWizardStep && flow.herdrOffer != nil ? finishTitle : WizardCopy.next, action: leaveMainBot).buttonStyle(.borderedProminent)
                        .disabled(!flow.mainBotReady).keyboardShortcut(.defaultAction)
                case .moreBots:
                    Button(flow.isLastWizardStep ? finishTitle : WizardCopy.next) { if flow.isLastWizardStep { finishWizard() } else { failure = nil; flow.apply(.advance) } }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                case .projects:
                    Button(finishTitle, action: finishWizard).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large)
        }
    }

    /// The wizard's last button says what it creates: the main bot alone, the main bot and the ticked ones, or (with
    /// a main bot that stays) only the ticked ones.
    private var finishTitle: String {
        let more = flow.step == .moreBots || flow.step == .projects ? flow.moreChosen.count : 0
        if flow.keptMainBot != nil { return more == 0 ? WizardCopy.finish : WizardCopy.addBots(more) }
        return more == 0 ? (flow.mainBotName.isEmpty ? WizardCopy.createMain : WizardCopy.create(flow.mainBotName)) : WizardCopy.createBots(more + 1)
    }

    /// The wizard opens where `AppStore.wizardStart` says; on the main bot of a server that is already set up it
    /// reads that server at once.
    private func restart() {
        abandonHerdr()
        flow = preset ?? store.wizardStart(); testing = presetTesting; failure = nil; finished = false; projects = nil
        if preset == nil, flow.readsSavedServer { testHerdr() }
    }

    /// On "Where are your projects?" the server's project servers are read with the access key Test used (the server
    /// may not be saved yet). Back on Connect or before it, another server may follow, so the reading is dropped.
    private func readProjects(_ step: SetupFlow.Step) {
        if step == .welcome || step == .herdr { projects = nil; return }
        guard step == .projects, projects == nil, presetProjects == nil, let server = flow.herdrServer else { return }
        let key = flow.herdrKey, store = store
        projects = HerdrProjectsModel { try store.herdrClient(for: server, token: key) }
    }

    private func cancel() { FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)); abandonHerdr(); dismiss() }

    private func back() {
        failure = nil
        let tested = flow.herdrServer
        flow.apply(.back)
        if flow.step == .welcome { store.abandonSetupHerdr(tested) }
    }

    /// Closes the forward Connect's Test opened, unless the last button saved its server.
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
                                                   more: flow.step == .moreBots || flow.step == .projects ? flow.moreChosen : [], offer: flow.herdrOffer,
                                                   projects: flow.step == .projects ? flow.mainProjects : [])
            finished = true
            store.open(main); store.composerFocus = main.id
            showMainWindow(); closeWindow()
        } catch { failure = SetupCopy.failed }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == AppConstants.name }) { window.makeKeyAndOrderFront(nil) } else { openWindow(id: ContentView.windowID) }
    }
}
