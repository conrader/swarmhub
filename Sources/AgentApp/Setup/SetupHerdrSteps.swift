import AppKit
import SwiftUI

/// Where the wizard is, as a row of dots under its content: the current step is the dark one. `count` is one less
/// once the server is known to offer nothing for the optional bots.
struct SetupWizardProgress: View {
    let current: Int
    var count = WizardCopy.steps.count
    /// The step's name where it is not one of the usual four.
    var name: String? = nil
    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle().fill(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary)).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(WizardCopy.stepLabel(current, of: count, name: name))
    }
}

/// The app's own icon where it runs as an app; a plain mark where it runs as a bare program (a render, a test).
struct SetupAppMark: View {
    var size: CGFloat = 72
    var body: some View {
        if Bundle.main.bundleIdentifier != nil {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().interpolation(.high).frame(width: size, height: size).accessibilityHidden(true)
        } else {
            SymbolTile(symbol: "bubble.left.and.bubble.right.fill", colour: .blue, size: size * 0.86)
        }
    }
}

extension HerdrServer.Kind {
    /// The symbol and colour a place bots can run has wherever it is offered.
    var mark: (symbol: String, colour: Color) {
        switch self {
        case .local: ("laptopcomputer", .blue)
        case .ssh: ("server.rack", .indigo)
        case .address: ("link", .teal)
        }
    }
}

/// Step 1: one sentence on what the app is, and where the bots run, as a few large options. This Mac is first and is
/// selected; a server is reached over SSH (the app opens the connection) or by an address someone already forwarded;
/// a ready-made server is only announced (`ManagedHosting.isAvailable` is false: nothing can be ordered, sent or
/// charged). A click selects, Continue (or Return, or a double click) goes on.
struct SetupHerdrWelcomeStep: View {
    @Binding var flow: SetupFlow
    let advance: () -> Void
    var body: some View {
        VStack(spacing: 22) {
            HeroHeader(title: WizardCopy.welcomeTitle, detail: WizardCopy.welcomeIntro) { SetupAppMark() }
            VStack(alignment: .leading, spacing: 8) {
                Text(WizardCopy.whereTitle).font(.headline).padding(.bottom, 2).accessibilityAddTraits(.isHeader)
                place(.local, SetupCopy.herdrLocalTitle, WizardCopy.localDetail)
                place(.ssh, SetupCopy.herdrSSHTitle, WizardCopy.sshDetail)
                place(.address, SetupCopy.herdrAddressTitle, WizardCopy.addressDetail)
                OptionCard(symbol: "shippingbox.fill", colour: .gray, title: SetupCopy.herdrReadyMadeTitle, detail: SetupCopy.herdrReadyMadeDetail, badge: ManagedHosting.badge, selected: false, select: {})
                    .disabled(!ManagedHosting.isAvailable).opacity(ManagedHosting.isAvailable ? 1 : 0.55)
            }.frame(maxWidth: AppleMetrics.column + 40)
        }
    }

    private func place(_ kind: HerdrServer.Kind, _ title: String, _ detail: String) -> some View {
        OptionCard(symbol: kind.mark.symbol, colour: kind.mark.colour, title: title, detail: detail, selected: flow.place == kind,
                   select: { flow.place = kind }, open: { flow.place = kind; advance() })
    }
}

/// Step 2, Connect: the place chosen, what Test said in plain words, and the fields for that place, each on its own.
/// This Mac needs nothing typed, so all of its fields are folded away. With nothing running here it says so and how
/// to start it; the app does not include, install or start Herdr itself yet.
struct SetupHerdrStep: View {
    @Binding var flow: SetupFlow
    let testing: Bool
    let test: () -> Void
    @State private var showDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// Which of the result's looks is showing, so the change from checking to connected is one short move.
    private var resultKind: Int {
        if testing { return 1 }
        if flow.herdrNothingHere != nil { return 2 }
        if flow.herdrFailure != nil || flow.herdrNoPrograms { return 3 }
        return flow.herdrReady ? 4 : 0
    }

    /// What Test said comes first, so it is in view whatever the fields below need. What nobody has to type (the
    /// access key that is read without typing, the port, the server's name in the app) is folded away.
    var body: some View {
        VStack(spacing: 22) {
            HeroHeader(title: header, detail: intro) { SymbolTile(symbol: flow.herdr.kind.mark.symbol, colour: flow.herdr.kind.mark.colour, size: 60) }
            VStack(alignment: .leading, spacing: 18) {
                result.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: resultKind)
                if flow.herdr.kind != .local { fields(.main) }
                QuietFold(title: WizardCopy.details, isOpen: Binding(get: { showDetails || asksForKey }, set: { showDetails = $0 })) { fields(.details) }
            }.frame(maxWidth: AppleMetrics.column)
        }
    }

    @ViewBuilder private var result: some View {
        if testing {
            StatusCard(kind: .working, title: SetupCopy.testing).transition(.opacity)
        } else if let port = flow.herdrNothingHere {
            StatusCard(kind: .warning, title: WizardCopy.nothingHere(port: port), detail: WizardCopy.nothingHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(WizardCopy.nothingCommand).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    CopyBox(text: Self.startCommand, copyLabel: WizardCopy.copy, copiedLabel: WizardCopy.copied)
                    Text(WizardCopy.nothingElse).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 4)
            }.transition(.opacity)
        } else if let failure = flow.herdrFailure {
            StatusCard(kind: .warning, title: WizardCopy.notConnected, detail: failure).transition(.opacity)
        } else if flow.herdrNoPrograms, let server = flow.herdrServer {
            StatusCard(kind: .warning, title: WizardCopy.notReady, detail: HerdrSetupProblem.noPrograms.line(for: server)).transition(.opacity)
        } else if flow.herdrReady, let server = flow.herdrServer, let offer = flow.herdrOffer {
            StatusCard(kind: .good, title: WizardCopy.connected(server.name), detail: WizardCopy.canRun(offer.names, count: Set(offer.programs.map(\.name)).count)).transition(.opacity)
        }
    }
}

/// Step 3: the server's main bot, made the way a contact is: a large avatar, its name typed directly under it, what
/// it should know, and the agent program and model it starts on as galleries of the server's own names with the
/// server's default selected. A server that already has bots also offers each of them: its main bot stays unless the
/// person chooses otherwise. A server that was set up before is read first; until then the step waits.
struct SetupMainBotStep: View {
    @EnvironmentObject private var store: AppStore
    @Binding var flow: SetupFlow
    let submit: () -> Void
    @State private var pickingAvatar = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            if let offer = flow.herdrOffer, let server = flow.herdrServer {
                identity(server)
                VStack(alignment: .leading, spacing: 20) {
                    if !flow.herdrBots.isEmpty { who }
                    if flow.keptMainBot == nil {
                        StandaloneField(title: WizardCopy.instructions, text: $flow.mainBot.instructions, prompt: WizardCopy.instructionsPrompt, lines: 2...4)
                        runsOn(offer)
                        Text(WizardCopy.runsOn(server.name)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: AppleMetrics.column)
            } else {
                HeroHeader(title: WizardCopy.mainTitle, detail: WizardCopy.mainIntro) { SymbolTile(symbol: "star.fill", colour: .orange, size: 60) }
                StatusCard(kind: .working, title: WizardCopy.reading(flow.herdr.server(id: "")?.name ?? "")).frame(maxWidth: AppleMetrics.column)
            }
        }
    }

    /// The avatar as it will look (a click opens the app's own picker), the star every main bot carries, and the
    /// name typed directly beneath; for a bot that stays, its own avatar and name.
    @ViewBuilder private func identity(_ server: HerdrServer) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tint).accessibilityHidden(true)
                Text(WizardCopy.mainTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            }
            if let kept = flow.keptMainBot {
                if let bot = store.bots.first(where: { $0.id == kept.id }) { BotAvatar(bot: bot, size: 84) } else {
                    let mark = GrokDefaultLook.mark(for: kept.id.uuidString.lowercased())
                    AvatarMarkView(shape: mark.shape, colour: AvatarColour(rawValue: mark.colour) ?? .gray, size: 84, mode: .still, seed: kept.id.uuidString.lowercased())
                }
                Text(kept.name).font(.system(size: 24, weight: .bold))
                Text(WizardCopy.keeps(kept.name, server: server.name, isMain: kept.isMain)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: AppleMetrics.column)
            } else {
                avatar
                TextField(WizardCopy.name, text: $flow.mainBot.name, prompt: Text(WizardCopy.name))
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
                    .padding(.vertical, 6).padding(.horizontal, 14).frame(width: 300)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .focused($nameFocused).onSubmit(submit).accessibilityLabel(WizardCopy.name)
                    .onAppear { nameFocused = true }
                if let problem = flow.mainBotProblem {
                    Text(problem).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: AppleMetrics.column)
                } else {
                    Text(WizardCopy.mainIntro).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: AppleMetrics.column)
                }
            }
        }.frame(maxWidth: .infinity)
    }

    private var avatar: some View {
        let mark = flow.mainBot.avatar.previewMark(seed: HerdrMainBotDraft.avatarSeed)
        return Button { pickingAvatar = true } label: {
            AvatarMarkView(shape: mark.shape, colour: AvatarColour(rawValue: mark.colour) ?? .gray, size: 84, mode: .still, seed: HerdrMainBotDraft.avatarSeed)
                .frame(width: 96, height: 92)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.secondary)
                        .background(Circle().fill(AppColor.panel).padding(1)).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(WizardCopy.avatarHelp).accessibilityLabel(WizardCopy.avatarHelp)
        .popover(isPresented: $pickingAvatar, arrowEdge: .trailing) {
            AvatarPickerView(choice: $flow.mainBot.avatar, seed: HerdrMainBotDraft.avatarSeed, hint: WizardCopy.avatarHint).padding(16).frame(width: 440)
        }
    }

    /// A new bot, or one of the bots already on the server: its main bot carries the star.
    private var who: some View {
        let choices = [NamedChoice(id: "", name: WizardCopy.mainNew)] + flow.herdrBots.map { NamedChoice(id: $0.id.uuidString, name: $0.name, note: $0.isMain ? WizardCopy.mainNow : nil) }
        return SettingBlock(title: WizardCopy.mainChoice) {
            TileGallery(items: choices, isSelected: { $0.id == (flow.mainBot.keep?.uuidString ?? "") }, name: \.name, select: { flow.mainBot.keep = UUID(uuidString: $0.id) }) { choice in
                NameTile(name: choice.name, note: choice.note, symbol: choice.id.isEmpty ? "plus" : choice.note == nil ? nil : "star.fill")
            }
        }
    }

    /// The agent program and the model, by the server's names, each as a gallery. A program for which the server
    /// lists no models picks its own; the first model the server lists is the default and is selected.
    @ViewBuilder private func runsOn(_ offer: HerdrOffer) -> some View {
        SettingBlock(title: WizardCopy.program) {
            TileGallery(items: offer.programs, isSelected: { $0.template == flow.mainBot.template }, name: { offer.label($0) },
                        select: { if flow.mainBot.template != $0.template { flow.mainBot.template = $0.template; flow.mainBot.model = "" } }) { NameTile(name: offer.label($0)) }
        }
        if let program = offer.program(flow.mainBot.template), program.takesModel, let first = program.defaultModel {
            let models = program.models.map { NamedChoice(id: $0.id, name: HerdrProgram.modelName($0), note: $0.id == first.id ? WizardCopy.defaultNote : nil) }
            SettingBlock(title: WizardCopy.model) {
                TileGallery(items: models, isSelected: { flow.mainBot.model.isEmpty ? $0.id == first.id : $0.id == flow.mainBot.model }, name: \.name,
                            select: { flow.mainBot.model = $0.id == first.id ? "" : $0.id }) { NameTile(name: $0.name, note: $0.note) }
            }
        } else {
            SettingBlock(title: WizardCopy.model, detail: HerdrAgentReading.programPicks) { EmptyView() }
        }
    }
}

/// Step 4, optional: one bot per other agent program the server offers, each on that program's default model, as
/// large options. None is chosen to begin with, so nothing is added unless the person asks for it.
struct SetupMoreBotsStep: View {
    @Binding var flow: SetupFlow
    var body: some View {
        VStack(spacing: 22) {
            HeroHeader(title: WizardCopy.moreTitle, detail: WizardCopy.moreIntro(server: flow.herdrServer?.name ?? "", main: flow.mainBotName)) {
                SymbolTile(symbol: "person.2.fill", colour: .green, size: 60)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(flow.moreChoices) { program in
                    let chosen = flow.moreBots.contains(program.template)
                    OptionCard(symbol: "plus.bubble.fill", colour: .purple, title: flow.herdrOffer?.label(program) ?? program.name,
                               detail: WizardCopy.moreDetail(program.name, model: program.defaultModel.map(HerdrProgram.modelName)), selected: chosen, multiple: true,
                               select: { if chosen { flow.moreBots.remove(program.template) } else { flow.moreBots.insert(program.template) } })
                }
                Text(WizardCopy.moreNone).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            }.frame(maxWidth: AppleMetrics.column)
        }
    }
}
