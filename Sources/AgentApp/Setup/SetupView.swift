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
    @State private var savedHostID: String?
    @AccessibilityFocusState private var progressFocused: Bool
    @State private var loginServer: HerdrServer?
    @State private var testing = false
    @State private var localSetupTask: Task<Void, Never>?
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
                    case .welcome:
                        SetupHerdrWelcomeStep(flow: $flow, advance: pickPlace, saved: store.herdrConfigured ? store.herdrServers : [],
                                              savedHostID: $savedHostID)
                    case .herdr: SetupHerdrStep(flow: $flow, testing: testing, test: testHerdr, answer: { store.answerInTerminal($0) }, checkAgain: checkAIs)
                    case .mainBot: SetupMainBotStep(flow: $flow, submit: leaveMainBot)
                    case .moreBots: SetupMoreBotsStep(flow: $flow)
                    case .projects: if let model = presetProjects ?? projects { SetupProjectsStep(flow: $flow, model: model) }
                    }
                }.frame(maxWidth: .infinity, alignment: .top).padding(.horizontal, 44).padding(.top, 34).padding(.bottom, 20)
            }.scrollBounceBehavior(.basedOnSize)
            if let failure { Text(failure).font(.callout).foregroundStyle(AppColor.caution).padding(.horizontal, 24).padding(.bottom, 8) }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(minWidth: preset == nil ? 560 : Self.size.width, idealWidth: Self.size.width,
               maxWidth: preset == nil ? .infinity : Self.size.width,
               minHeight: preset == nil ? 530 : (presetHeight ?? Self.size.height), idealHeight: presetHeight ?? Self.size.height,
               maxHeight: preset == nil ? .infinity : (presetHeight ?? Self.size.height)).background(AppColor.panel)
        .onAppear { if Self.cameBackUnasked(preset: preset, generation: store.setupGeneration) { closeUnasked() } else { restart() } }
        .onChange(of: store.setupGeneration) { _, _ in unasked = false; restart() }
        .onChange(of: flow.step, initial: true) { _, step in readProjects(step); progressFocused = true }
        .sheet(item: $loginServer) { server in
            SSHLoginSheet(server: server) { signedIn in
                flow.herdr.sshDestination = signedIn.sshUser + "@" + signedIn.sshHost
                testHerdr()
            }
        }
        .onAppear { closed = false }
        .onDisappear { closed = true; cancelLocalDownload(); if !unasked, !finished { FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)) }; abandonHerdr() }
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
        VStack(spacing: 8) {
            SetupWizardProgress(current: flow.stepIndex, count: flow.stepCount, name: flow.step == .projects ? WizardCopy.projectsStep : nil)
                .accessibilityFocused($progressFocused)
            HStack(spacing: 10) {
                if flow.canGoBack {
                    Button(flow.localSetup?.downloadFailed == true ? "Change host" : SetupCopy.back, action: back)
                        .disabled(flow.localSetup?.isInstalling == true)
                }
                Spacer()
                Button(SetupCopy.cancel, action: cancel).keyboardShortcut(.cancelAction).disabled(flow.localSetup?.isInstalling == true)
                switch flow.step {
                case .welcome:
                    Button(WizardCopy.next, action: pickPlace).buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                case .herdr:
                    if let setup = flow.localSetup {
                        if setup.canStopDownload {
                            Button("Stop", action: cancelLocalDownload)
                        } else {
                            Button(localSetupButton(for: setup), action: setUpThisMac).buttonStyle(.appleProminent)
                                .disabled(setup.isWorking || testing || flow.herdr.problem != nil).keyboardShortcut(.defaultAction)
                        }
                    } else if flow.herdrNoPrograms || !flow.missingStarterPrograms.isEmpty, flow.herdr.kind == .local, flow.localReport != nil, !testing {
                        // An AI program installed since is found by setting this Mac up again, which changes nothing else.
                        Button(SetupCopy.testAgain, action: setUpThisMac).buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                    } else if flow.herdrReady, !testing {
                        Button("Import from Grok Bot", action: startGrokImport)
                            .keyboardShortcut(store.setupForGrok ? .defaultAction : nil)
                        if !store.setupForGrok {
                            Button("Create a bot") { failure = nil; flow.apply(.advance) }
                                .buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                        }
                    } else {
                        Button(testing ? SetupCopy.testing : flow.herdrOutcome != nil ? SetupCopy.testAgain : SetupCopy.test, action: testHerdr).buttonStyle(.appleProminent)
                            .disabled(testing || flow.herdr.problem != nil).keyboardShortcut(.defaultAction)
                    }
                case .mainBot:
                    if !flow.isLastWizardStep && flow.herdrOffer != nil {
                        Button("More options") { flow.apply(.advance) }.disabled(!flow.mainBotReady)
                    }
                    Button(failure == nil ? finishTitle : "Retry saving bot", action: leaveMainBot).buttonStyle(.appleProminent)
                        .disabled(!flow.mainBotReady).keyboardShortcut(.defaultAction)
                case .moreBots:
                    Button(flow.isLastWizardStep ? finishTitle : WizardCopy.next) { if flow.isLastWizardStep { finishWizard() } else { failure = nil; flow.apply(.advance) } }
                        .buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                case .projects:
                    Button(failure == nil ? (flow.mainProjects.isEmpty ? "Finish without projects" : finishTitle) : "Retry saving bot", action: finishWizard).buttonStyle(.appleProminent).keyboardShortcut(.defaultAction)
                }
            }.controlSize(.large)
        }
    }

    /// The wizard's last button says what it creates: the main bot alone, the main bot and the ticked ones, or (with
    /// a main bot that stays) only the ticked ones.
    private var finishTitle: String {
        let more = flow.moreChosen.count
        if flow.keptMainBot != nil { return more == 0 ? WizardCopy.finish : WizardCopy.addBots(more) }
        return more == 0 ? (flow.mainBotName.isEmpty ? WizardCopy.createMain : WizardCopy.create(flow.mainBotName)) : WizardCopy.createBots(more + 1)
    }

    /// The wizard opens where `AppStore.wizardStart` says; on the main bot of a server that is already set up it
    /// reads that server at once.
    private func restart() {
        cancelLocalDownload()
        abandonHerdr()
        flow = preset ?? SetupFlow(); testing = presetTesting; failure = nil; finished = false; projects = nil
        savedHostID = nil
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

    private func cancel() { cancelLocalDownload(); FirstRun.dismissed(store.defaults, hasBots: FirstRun.hasRealAgents(store.bots)); abandonHerdr(); dismiss() }

    private func back() {
        cancelLocalDownload()
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
        failure = nil
        if let savedHostID, let server = store.herdrServer(id: savedHostID) {
            flow.connectToSaved(server)
            testHerdr()
        } else {
            flow.apply(.pickHerdr(flow.place))
            if flow.place == .local { testHerdr() }
        }
    }

    /// Connect's Test, and the reading of a server that was set up before (the window then waits on the main bot).
    private func testHerdr() {
        guard flow.herdr.problem == nil, !testing else { return }
        let typed = flow.herdr, step = flow.step
        testing = true; failure = nil
        Task { await checkHerdr(typed, step: step) }
    }

    private func checkHerdr(_ typed: HerdrServerDraft, step: SetupFlow.Step) async {
        var draft = typed
        // This Mac's usual port can lead to another server: its own port is found before anything is asked.
        if let port = await store.thisMacPort(for: typed), !closed, !Task.isCancelled, flow.step == step, flow.herdr == typed {
            flow.localMovedFrom = Int(typed.port.trimmingCharacters(in: .whitespaces)); flow.herdr.port = String(port); draft = flow.herdr
        }
        guard !Task.isCancelled else { testing = false; return }
        let outcome = await store.testSetupHerdr(draft)
        testing = false
        let current = !closed && !Task.isCancelled && flow.step == step && flow.herdr == draft
        if current, flow.localSetup == .working(.checkingConnection) { flow.apply(.localSetup(nil)) }
        guard case .connected(let server, _, _) = outcome else {
            guard current else { return }
            flow.apply(.herdrTest(outcome))
            if case .sshLoginRequired(let server) = outcome { loginServer = server }
            if case .nothingHere = outcome, draft.kind == .local, flow.localSetup == nil { flow.apply(.localSetup(.offer(hasCore: store.localService.hasCore))) }
            return
        }
        guard current else { store.abandonSetupHerdr(server); return }
        let existing = store.setupHerdrBots(on: server)
        flow.apply(.herdrTest(outcome, bots: existing))
        if existing.count == 1, let only = existing.first, only.needsFirstConnection { flow.mainBot.keep = only.id }
        if server.kind == .local, step == .herdr { await lookAtThisMac(server) }
    }

    private func localSetupButton(for setup: HerdrLocalSetup) -> String {
        switch setup {
        case .offer: WizardCopy.setUp
        case .working: WizardCopy.settingUp
        case .failedDownload: "Retry download"
        case .failed: "Retry setup"
        }
    }

    private func cancelLocalDownload() {
        // Once the verified program starts mutating LaunchAgents and templates, let that transaction finish.
        guard flow.localSetup?.isInstalling != true else { return }
        if let localSetupTask {
            localSetupTask.cancel()
            if flow.localSetup?.canStopDownload == true {
                flow.apply(.localSetup(.failedDownload("Download stopped. Retry to continue setup.")))
            }
        }
    }

    /// The one button of a Mac where nothing runs yet. It fetches the service, checks it, has it set this Mac up,
    /// and then connects as it would have.
    private func setUpThisMac() {
        guard flow.step == .herdr, flow.herdr.kind == .local, localSetupTask == nil, let server = flow.herdr.server(id: "") else { return }
        let draft = flow.herdr, answers = flow.localAnswers
        let retryInstall = if case .failed? = flow.localSetup { true } else { false }
        failure = nil; flow.apply(.localSetup(.working(.checkingRelease)))
        localSetupTask = Task {
            defer { localSetupTask = nil }
            do {
                let report = try await store.setUpThisMac(port: server.port, answerFirstTime: answers, retryInstall: retryInstall) { step in
                    if !closed, !Task.isCancelled, flow.herdr == draft { flow.apply(.localSetup(.working(step))) }
                }
                guard !closed, !Task.isCancelled, flow.step == .herdr, flow.herdr == draft else { return }
                flow.apply(.localReport(report)); flow.apply(.localSetup(.working(.checkingConnection)))
                testing = true
                await checkHerdr(draft, step: .herdr)
            } catch {
                guard !closed, !Task.isCancelled, flow.step == .herdr, flow.herdr == draft else { return }
                let line = HerdrLocalSetup.line(for: error)
                let downloadFailed = flow.localSetup?.canStopDownload == true && (error as? HerdrLocalFailure)?.kind != "setup_busy"
                flow.apply(.localSetup(downloadFailed ? .failedDownload(line) : .failed(line)))
            }
        }
    }

    /// This Mac answers: read what its service says is installed, then find out whether each AI can take a message.
    private func lookAtThisMac(_ server: HerdrServer) async {
        if flow.localReport == nil, let report = await store.localReport(port: server.port), !closed, flow.herdrServer == server { flow.apply(.localReport(report)) }
        checkAIs()
    }

    /// Starts each AI of this Mac once, with no task, and shows whether it is ready or asks something first.
    private func checkAIs() {
        guard flow.step == .herdr, let server = flow.herdrServer, server.kind == .local, let offer = flow.herdrOffer, !flow.aiChecking else { return }
        let key = flow.herdrKey, report = flow.localReport
        for program in offer.programs where program.template != "swarmhub-opencode" && (flow.starter?.programs.contains(program.starterName) ?? true) {
            let note = report?.program(template: program.template)?.firstTime
            flow.apply(.aiCheck(HerdrAICheck(template: program.template, name: program.name, note: note)))
            Task {
                let check = await store.checkAI(program, on: server, key: key, note: note)
                if !closed, flow.herdrServer == server { flow.apply(.aiCheck(check)) }
            }
        }
    }

    /// Return in the name field creates the main bot. More options opens the remaining steps.
    private func leaveMainBot() {
        guard flow.step == .mainBot, flow.mainBotReady else { return }
        failure = nil
        finishWizard()
    }

    /// The wizard's one write: the server, the main bot and the ticked bots. Then the main window shows the main
    /// bot's chat with the keyboard in its composer.
    private func finishWizard() {
        guard flow.step == .mainBot || flow.isLastWizardStep, flow.mainBotReady, !finished else { return }
        do {
            let main = try store.commitSetupWizard(server: flow.herdrServer, key: flow.herdrKey, main: flow.mainBot,
                                                   more: flow.moreChosen, offer: flow.herdrOffer,
                                                   projects: flow.step == .projects ? flow.mainProjects : [])
            finished = true
            store.open(main); store.composerFocus = main.id
            showMainWindow(); closeWindow()
        } catch { failure = SetupCopy.failed }
    }

    private func startGrokImport() {
        guard flow.herdrReady, let server = flow.herdrServer, let offer = flow.herdrOffer else { return }
        store.saveHerdrServer(server, token: flow.herdrKey)
        store.grokDestination = GrokDestination(serverID: server.id, offer: offer, testedHost: server)
        finished = true
        showMainWindow()
        closeWindow()
        store.showingGrokImport = true
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title == AppConstants.name }) { window.makeKeyAndOrderFront(nil) } else { openWindow(id: ContentView.windowID) }
    }
}
