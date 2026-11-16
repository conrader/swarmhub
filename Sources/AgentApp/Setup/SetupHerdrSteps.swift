import SwiftUI

/// The strip at the top of the wizard: its steps, the current one marked and the ones behind it ticked. `count` is 3
/// once the server is known to offer nothing for the fourth, the optional bots.
struct SetupWizardProgress: View {
    let current: Int
    var count = WizardCopy.steps.count
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(WizardCopy.steps.prefix(count).enumerated()), id: \.offset) { index, title in
                if index > 0 { Rectangle().fill(AppColor.separator).frame(width: 22, height: 1) }
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(index <= current ? Color.accentColor : Color.primary.opacity(0.1)).frame(width: 18, height: 18)
                        if index < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        } else {
                            Text(String(index + 1)).font(.system(size: 10, weight: .semibold)).foregroundStyle(index == current ? Color.white : Color.secondary)
                        }
                    }
                    Text(title).font(.caption.weight(index == current ? .semibold : .regular)).foregroundStyle(index == current ? Color.primary : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(WizardCopy.stepLabel(current, of: count))
    }
}

/// Step 1: one sentence on what the app is, and where the bots run. This Mac is first and is selected; a server is
/// reached over SSH (the app opens the connection) or by an address someone already forwarded; a ready-made server is
/// only announced (`ManagedHosting.isAvailable` is false: nothing can be ordered, sent or charged). A click selects,
/// Continue (or Return, or a double click) goes on.
struct SetupHerdrWelcomeStep: View {
    @Binding var flow: SetupFlow
    let advance: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WizardCopy.welcomeTitle).font(.title2.bold())
            Text(WizardCopy.welcomeIntro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(WizardCopy.whereTitle).font(.headline).padding(.top, 10).padding(.bottom, 2)
            place(.local, SetupCopy.herdrLocalTitle, WizardCopy.localDetail)
            place(.ssh, SetupCopy.herdrSSHTitle, WizardCopy.sshDetail)
            place(.address, SetupCopy.herdrAddressTitle, WizardCopy.addressDetail)
            SetupPlaceCard(title: SetupCopy.herdrReadyMadeTitle, detail: SetupCopy.herdrReadyMadeDetail, badge: ManagedHosting.badge, selected: false, select: {}, open: {})
                .disabled(!ManagedHosting.isAvailable).opacity(ManagedHosting.isAvailable ? 1 : 0.55)
        }
    }

    private func place(_ kind: HerdrServer.Kind, _ title: String, _ detail: String) -> some View {
        SetupPlaceCard(title: title, detail: detail, badge: nil, selected: flow.place == kind, select: { flow.place = kind }, open: { flow.place = kind; advance() })
    }
}

/// One place bots can run: a radio mark, a title, one plain line and an optional badge.
struct SetupPlaceCard: View {
    let title: String; let detail: String; let badge: String?
    let selected: Bool
    let select: () -> Void; let open: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.system(size: 16)).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let badge { Text(badge).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.1))) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColor.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).simultaneousGesture(TapGesture(count: 2).onEnded { _ in open() })
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Step 2, Connect: what Test said in plain words, and the fields for the place chosen. This Mac needs nothing typed,
/// so all of its fields are folded away. With nothing running here it says so and how to start it; the app does not
/// include, install or start Herdr itself yet.
struct SetupHerdrStep: View {
    @Binding var flow: SetupFlow
    let testing: Bool
    let test: () -> Void
    @State private var showDetails = false

    /// The start script of the Herdr workspace checkout; shown verbatim.
    static let startCommand = "sh HerdrWorkspace/dev/start-local.sh"

    private var header: String {
        switch flow.herdr.kind { case .local: WizardCopy.localHeader; case .ssh: WizardCopy.sshHeader; case .address: WizardCopy.addressHeader }
    }
    private var intro: String {
        switch flow.herdr.kind { case .local: WizardCopy.localIntro; case .ssh: WizardCopy.sshIntro; case .address: WizardCopy.addressIntro }
    }
    private func fields(_ part: HerdrServerFields.Part) -> HerdrServerFields {
        HerdrServerFields(draft: $flow.herdr, part: part, submit: { if flow.herdr.problem == nil, !testing, !flow.herdrReady { test() } })
    }

    /// Test asked for the access key, or refused the one it found: the folded field for it is opened.
    private var asksForKey: Bool {
        guard flow.herdr.kind != .address, let failure = flow.herdrFailure, let server = flow.herdr.server(id: "") else { return false }
        return failure == HerdrSetupProblem.noKey.line(for: server) || failure == HerdrSetupProblem.wrongKey.line(for: server)
    }

    /// What Test said comes first, so it is in view whatever the fields below need. What nobody has to type (the
    /// access key that is read without typing, the port, the server's name in the app) is folded away.
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header).font(.title2.bold())
            Text(intro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                result
                if flow.herdr.kind != .local { Section { fields(.main) } }
                Section { DisclosureGroup(isExpanded: Binding(get: { showDetails || asksForKey }, set: { showDetails = $0 })) { fields(.details) } label: { Text(WizardCopy.details) } }
            }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20).padding(.bottom, -20).padding(.top, -6)
        }
    }

    @ViewBuilder private var result: some View {
        if testing {
            Section { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(SetupCopy.testing).foregroundStyle(.secondary) } }
        } else if let port = flow.herdrNothingHere {
            Section {
                Label(WizardCopy.nothingHere(port: port), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(WizardCopy.nothingHelp).font(.callout).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(WizardCopy.nothingCommand).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack { Text(Self.startCommand).font(.callout.monospaced()).textSelection(.enabled); CopyButton(text: Self.startCommand) }
                }
                Text(WizardCopy.nothingElse).font(.callout).foregroundStyle(.secondary)
            }
        } else if let failure = flow.herdrFailure {
            Section { problem(failure) }
        } else if flow.herdrNoPrograms, let server = flow.herdrServer {
            Section { problem(HerdrSetupProblem.noPrograms.line(for: server)) }
        } else if flow.herdrReady, let server = flow.herdrServer, let offer = flow.herdrOffer {
            Section {
                Label(WizardCopy.connected(server.name), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(WizardCopy.canRun(offer.names, count: Set(offer.programs.map(\.name)).count)).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func problem(_ line: String) -> some View {
        Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

/// Step 3: the server's main bot. A new one gets a name (suggested, editable), an avatar, optional instructions, and
/// the agent program and model it starts on, both by the server's own names with the server's default selected. A
/// server that already has bots also offers each of them: its main bot stays unless the person chooses otherwise.
/// A server that was set up before is read first; until then the step waits.
struct SetupMainBotStep: View {
    @Binding var flow: SetupFlow
    let submit: () -> Void
    @State private var pickingAvatar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WizardCopy.mainTitle).font(.title2.bold())
            Text(WizardCopy.mainIntro).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let offer = flow.herdrOffer, let server = flow.herdrServer {
                Form {
                    Section {
                        if !flow.herdrBots.isEmpty {
                            Picker(WizardCopy.mainChoice, selection: $flow.mainBot.keep) {
                                Text(WizardCopy.mainNew).tag(UUID?.none)
                                ForEach(flow.herdrBots) { bot in Text(WizardCopy.mainExisting(bot.name, isMain: bot.isMain)).tag(UUID?.some(bot.id)) }
                            }
                        }
                        if let kept = flow.keptMainBot {
                            Text(WizardCopy.keeps(kept.name, server: server.name, isMain: kept.isMain)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            TextField(WizardCopy.name, text: $flow.mainBot.name).onSubmit(submit)
                            LabeledContent(WizardCopy.avatar) { avatar }
                            TextField(WizardCopy.instructions, text: $flow.mainBot.instructions, prompt: Text(WizardCopy.instructionsPrompt), axis: .vertical).lineLimit(1...3)
                        }
                    }
                    if flow.keptMainBot == nil {
                        Section { runsOn(offer) } footer: { footer(server) }
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20).padding(.bottom, -20).padding(.top, -6)
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(WizardCopy.reading(flow.herdr.server(id: "")?.name ?? "")).foregroundStyle(.secondary) }.padding(.top, 18)
            }
        }
    }

    /// The avatar as it will look, and a button that opens the app's own picker.
    private var avatar: some View {
        let mark = flow.mainBot.avatar.previewMark(seed: HerdrMainBotDraft.avatarSeed)
        return HStack(spacing: 10) {
            AvatarMarkView(shape: mark.shape, colour: AvatarColour(rawValue: mark.colour) ?? .gray, size: 22, mode: .still, seed: HerdrMainBotDraft.avatarSeed).frame(width: 26, height: 20)
            Button(SetupCopy.herdrChoose) { pickingAvatar = true }
                .help(WizardCopy.avatarHelp)
                .popover(isPresented: $pickingAvatar, arrowEdge: .trailing) {
                    AvatarPickerView(choice: $flow.mainBot.avatar, seed: HerdrMainBotDraft.avatarSeed, hint: WizardCopy.avatarHint).padding(16).frame(width: 440)
                }
        }
    }

    /// The agent program and the model, by the server's names. A program for which the server lists no models picks
    /// its own; the first model the server lists is the default and is selected.
    @ViewBuilder private func runsOn(_ offer: HerdrOffer) -> some View {
        if offer.programs.count > 1 {
            Picker(WizardCopy.program, selection: $flow.mainBot.template) { ForEach(offer.programs) { Text(offer.label($0)).tag($0.template) } }
                .onChange(of: flow.mainBot.template) { _, _ in flow.mainBot.model = "" }
        } else if let only = offer.programs.first {
            LabeledContent(WizardCopy.program) { Text(offer.label(only)).foregroundStyle(.secondary) }
        }
        if let program = offer.program(flow.mainBot.template), program.takesModel, let first = program.defaultModel {
            Picker(WizardCopy.model, selection: $flow.mainBot.model) {
                Text(WizardCopy.defaultModel(HerdrProgram.modelName(first))).tag("")
                ForEach(program.models.filter { $0.id != first.id }, id: \.id) { Text(HerdrProgram.modelName($0)).tag($0.id) }
            }
        } else {
            LabeledContent(WizardCopy.model) { Text(HerdrAgentReading.programPicks).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func footer(_ server: HerdrServer) -> some View {
        if let problem = flow.mainBotProblem, problem != WizardCopy.nameMissing {
            Text(problem).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(WizardCopy.runsOn(server.name)).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Step 4, optional: one bot per other agent program the server offers, each on that program's default model. Nothing
/// is ticked to begin with, so nothing is added unless the person asks for it.
struct SetupMoreBotsStep: View {
    @Binding var flow: SetupFlow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WizardCopy.moreTitle).font(.title2.bold())
            Text(WizardCopy.moreIntro(server: flow.herdrServer?.name ?? "", main: flow.mainBotName)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Section {
                    ForEach(flow.moreChoices) { program in
                        Toggle(isOn: Binding(get: { flow.moreBots.contains(program.template) }, set: { on in
                            if on { flow.moreBots.insert(program.template) } else { flow.moreBots.remove(program.template) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(flow.herdrOffer?.label(program) ?? program.name)
                                Text(WizardCopy.moreDetail(program.name, model: program.defaultModel.map(HerdrProgram.modelName))).font(.caption).foregroundStyle(.secondary)
                            }.padding(.leading, 4)
                        }.toggleStyle(.checkbox)
                    }
                } footer: { Text(WizardCopy.moreNone).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
            }.formStyle(.grouped).scrollContentBackground(.hidden).padding(.horizontal, -20).padding(.bottom, -20).padding(.top, -6)
        }
    }
}
