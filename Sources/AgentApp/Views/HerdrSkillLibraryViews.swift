import SwiftUI

// A Herdr server's library, for a workspace that serves it (`HerdrLibraryModel`): the calm card Settings and a bot's
// Details show (where things stand, one Sync button, a count per kind), and the sheet it opens with three areas,
// Overview, Library and Servers. The list of things, a thing's preview, installing and the repository are in the
// files beside this one. A workspace older than that keeps the switch list (`HerdrSkillsContent`).

extension HerdrLibraryKind {
    /// The colour of this kind's tile wherever it shows.
    var colour: Color {
        switch self { case .skills: AppColor.sage; case .agents: AppColor.plum; case .mcp: AppColor.sky; case .plugins: AppColor.sand; case .hooks: AppColor.clay }
    }
}

/// Where one thing stands, as a small coloured label.
struct LibraryStateChip: View {
    let state: HerdrLibraryItem.State
    var body: some View {
        let text = HerdrLibraryCopy.state(state)
        switch state {
        case .waiting: FactChip(text: text, symbol: "arrow.triangle.2.circlepath", colour: AppColor.caution)
        case .update: FactChip(text: text, symbol: "arrow.down.circle", colour: AppColor.sky)
        case .inSync: FactChip(text: text, symbol: "checkmark", colour: AppColor.good)
        case .off, .unknown: FactChip(text: text)
        }
    }
}

/// The overview's one card: where the library stands in a headline and a sentence, and the one thing to do about it.
struct LibraryHero: View {
    let library: HerdrLibrary
    var work: HerdrLibraryModel.Work? = nil
    /// A change is in the library and the last sync failed, with the line that says so.
    var behind: String? = nil
    /// The narrow Details panel puts the button under the words.
    var compact = false
    let sync: () -> Void
    let reload: () -> Void

    private var look: (symbol: String, colour: Color) {
        switch library.standing {
        case .inSync: ("checkmark", AppColor.sage)
        case .needsSync: ("arrow.triangle.2.circlepath", AppColor.clay)
        case .blocked, .partUnread, .unsure, .missing: ("exclamationmark", AppColor.sand)
        case .empty, .noTargets: ("tray", AppColor.olive)
        }
    }
    private var needsSync: Bool { if case .needsSync = library.standing { library.canSync } else { false } }
    private var needsLook: Bool { switch library.standing { case .blocked, .partUnread, .unsure, .missing: true; default: false } }

    var body: some View {
        let words = HerdrLibraryCopy.headline(library)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                SymbolTile(symbol: look.symbol, colour: look.colour, size: compact ? 38 : 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(words.title).font(compact ? .headline : .title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    Text(words.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if !compact { action }
            }
            if compact { action }
            if let behind, work != .syncing {
                Label(behind, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(AppColor.caution).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .appleCard(padding: compact ? 14 : 18)
    }

    @ViewBuilder private var action: some View {
        if work == .syncing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Syncing…").font(.callout).foregroundStyle(.secondary) }
        } else if needsSync || behind != nil {
            Button(action: sync) { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(work != nil)
        } else if needsLook {
            Button("Check again", action: reload).controlSize(.large).disabled(work != nil)
        }
    }
}

/// A count per kind, each a tile that opens the Library on that kind.
struct LibraryCountTiles: View {
    let library: HerdrLibrary
    var minimum: CGFloat = 96
    /// The narrow Details panel lays a tile out in one line: the mark, the count, the kind.
    var compact = false
    let open: (HerdrLibraryKind) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
            ForEach(HerdrLibraryKind.allCases) { kind in
                let count = library.count(of: kind)
                Button { open(kind) } label: {
                    Group {
                        if compact {
                            HStack(alignment: .center, spacing: 8) {
                                SymbolTile(symbol: kind.symbol, colour: kind.colour, size: 24)
                                Text(count.map(String.init) ?? "?").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(count == 0 ? .secondary : .primary)
                                Text(kind.title).font(.callout).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 0)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                SymbolTile(symbol: kind.symbol, colour: kind.colour, size: 28)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(count.map(String.init) ?? "?").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(count == 0 ? .secondary : .primary)
                                    Text(kind.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).appleCard(padding: compact ? 9 : 12).contentShape(RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
                }
                .buttonStyle(.plain).help(count == nil ? "\(kind.title) could not be read." : kind.explained)
                .accessibilityElement(children: .ignore).accessibilityLabel(count.map { kind.counted($0) } ?? "\(kind.title): could not be read").accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// What Settings → Servers → Skills and a bot's Details → Skills show for one server: the overview card and the way
/// into the library when the server serves it, and the switch list with one line about updating when it is older.
struct HerdrSkillsEntry: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryModel
    @ObservedObject var legacy: HerdrSkillsModel
    let server: HerdrServer
    var compact = false
    /// The project's name when this is a project's own library.
    var scopeName: String? = nil
    @State private var showLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .idle: Button("Show skills") { Task { await model.load() } }
            case .reading: StatusCard(kind: .working, title: "Checking…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The library could not be loaded", detail: why) { Button("Try again") { Task { await model.load() } }.padding(.top, 4) }
            case .older:
                HerdrSkillsContent(model: legacy, server: server, listHeight: nil)
                Label(HerdrLibraryCopy.fallback, systemImage: "arrow.up.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .ready: if let library = model.library { ready(library) }
            }
        }
        // Only the real app reads on its own; a preview or test store stays offline until asked. A server that was
        // older is asked again each time this shows, so the library appears once the server was updated.
        .task(id: server.id) { if model.phase == .idle || model.phase == .older, store.launchWorkEnabled { await model.load() } }
        .sheet(isPresented: $showLibrary) { HerdrLibrarySheet(model: model, servers: store.herdrLibraryServers, server: server, scopeName: scopeName) { showLibrary = false }.environmentObject(store) }
    }

    @ViewBuilder private func ready(_ library: HerdrLibrary) -> some View {
        LibraryHero(library: library, work: model.work, behind: model.behind, compact: compact, sync: { Task { await model.sync() } }, reload: { Task { await model.load() } })
        if library.installed {
            if let note = library.note { StatusCard(kind: .warning, title: note) }
            if !library.unread.isEmpty, library.waitingCount > 0 {
                StatusCard(kind: .warning, title: "Part of the library could not be read", detail: HerdrLibraryCopy.unread(library.unread))
            }
            LibraryCountTiles(library: library, minimum: compact ? 140 : 92, compact: compact) { kind in model.kind = kind; model.area = .library; showLibrary = true }
            HStack(spacing: 10) {
                // One prominent action at a time: Sync while something waits, else the way into the library.
                if model.work == nil, model.behind == nil, library.waitingCount == 0 {
                    Button("Open library") { open() }.buttonStyle(.borderedProminent).controlSize(.large)
                } else {
                    Button("Open library") { open() }.controlSize(.large)
                }
                if let note = model.note, model.work == nil {
                    Text(note.text).font(.callout).foregroundStyle(note.isProblem ? AnyShapeStyle(AppColor.caution) : AnyShapeStyle(.secondary)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(HerdrLibraryCopy.freshStart).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func open() { model.area = .overview; showLibrary = true }
}

/// The library as a sheet: a title, the three areas behind a segmented control, and a line at the bottom for what is
/// under way and what the last action did.
struct HerdrLibrarySheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryModel
    @ObservedObject var servers: HerdrLibraryServersModel
    let server: HerdrServer
    /// The project's name when this is a project's own library.
    var scopeName: String? = nil
    /// Renders show a taller sheet, so a long area is seen whole.
    var height: CGFloat = HerdrLibrarySheet.size.height
    var close: () -> Void = {}
    static let size = CGSize(width: 900, height: 680)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch model.area {
                    case .overview: HerdrLibraryOverview(model: model, server: server)
                    case .library: HerdrLibraryList(model: model)
                    case .servers: HerdrLibraryServers(model: servers, current: server)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            LibraryStatusStrip(model: model)
        }
        .frame(width: Self.size.width, height: height).background(AppColor.panel)
        .task(id: server.id) { if store.launchWorkEnabled { await model.opened() } }
        .sheet(item: model.question(at: .root)) { question in LibraryConfirmSheet(model: model, question: question, server: server) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.closePreview() } })) { HerdrLibraryPreviewSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.install != .closed }, set: { if !$0 { Task { await model.cancelInstall() } } })) { HerdrLibraryInstallSheet(model: model, server: server) }
        .sheet(isPresented: Binding(get: { model.conflict != nil }, set: { if !$0 { model.closeConflict() } })) { HerdrLibraryConflictSheet(model: model) }
    }

    private var header: some View {
        ZStack {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Library").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(scopeName.map { "\($0) on \(server.name)" } ?? server.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction).controlSize(.large)
            }
            Picker("Area", selection: $model.area) { ForEach(HerdrLibraryModel.Area.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330).controlSize(.large)
        }
        .padding(.horizontal, 28).padding(.vertical, 16)
    }
}

/// The Overview area: where the library stands, a count per kind, each AI the library is shared with and what waits
/// for it, and at the bottom the library's repository.
struct HerdrLibraryOverview: View {
    @ObservedObject var model: HerdrLibraryModel
    let server: HerdrServer

    var body: some View {
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            switch model.phase {
            case .idle, .reading: StatusCard(kind: .working, title: "Reading the library…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The library could not be loaded", detail: why) { Button("Try again") { Task { await model.load() } }.padding(.top, 4) }
            case .older: StatusCard(kind: .info, title: HerdrLibraryCopy.olderService)
            case .ready: if let library = model.library { ready(library) }
            }
        }
    }

    @ViewBuilder private func ready(_ library: HerdrLibrary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LibraryHero(library: library, work: model.work, behind: model.behind, sync: { Task { await model.sync() } }, reload: { Task { await model.load() } })
            if let note = library.note { StatusCard(kind: .warning, title: note) }
            if !library.unread.isEmpty, library.waitingCount > 0 || (library.syncBlocked ?? "").isEmpty == false {
                StatusCard(kind: .warning, title: "Part of the library could not be read", detail: HerdrLibraryCopy.unread(library.unread))
            }
        }
        if library.installed {
            VStack(alignment: .leading, spacing: 12) {
                GroupHeading(title: "In your library")
                LibraryCountTiles(library: library, minimum: 140) { kind in model.kind = kind; model.area = .library }
            }
            VStack(alignment: .leading, spacing: 12) {
                GroupHeading(title: "Your AIs", detail: "The AI programs on \(server.name) that get what is in your library.")
                if library.targets.isEmpty {
                    EmptyNote(symbol: "person.2.slash", title: "None yet", detail: "Share your library with an AI on this server, and its bots get your skills.", colour: AppColor.olive)
                } else {
                    let known = HerdrLibraryCopy.certainty(library)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(library.targets) { target in LibraryTargetCard(target: target, known: known) }
                    }
                }
                LibrarySharing(model: model, server: server)
            }
            if model.project == nil, let source = model.source { HerdrLibrarySourceCard(model: model, source: source) }
        }
    }
}

/// One AI the library is shared with: its name, and what waits for it in a sentence.
private struct LibraryTargetCard: View {
    let target: HerdrLibrary.Target
    let known: HerdrLibraryCopy.Certainty
    var body: some View {
        let waits = (target.waiting ?? 0) > 0
        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: "sparkles", colour: waits ? AppColor.clay : AppColor.olive, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name).font(.headline)
                Text(HerdrLibraryCopy.targetLine(target, known: known)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if waits { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(AppColor.caution).accessibilityHidden(true) }
            else if known == .whole { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColor.good).accessibilityHidden(true) }
        }
        .appleCard(padding: 12).accessibilityElement(children: .combine)
    }
}

/// Sharing the library with another agent program. The server is asked what it finds only when this is opened, and
/// a program is added only after the question that says what that means.
private struct LibrarySharing: View {
    @ObservedObject var model: HerdrLibraryModel
    let server: HerdrServer
    var body: some View {
        switch model.sharing {
        case .closed: Button("Share with another AI…") { Task { await model.openSharing() } }.disabled(model.isBusy)
        case .asking: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking \(server.name)…").font(.callout).foregroundStyle(.secondary) }
        case .failed(let why):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(why).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("Close") { model.closeSharing() }
            }
        case .offered(let agents):
            HStack(spacing: 10) {
                if agents.isEmpty { Text(HerdrLibraryCopy.nothingToShare).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                ForEach(agents, id: \.self) { agent in Button("Share with \(agent)…") { model.ask(.share(agent)) }.disabled(model.isBusy) }
                Button("Close") { model.closeSharing() }
            }
        }
    }
}

extension HerdrLibraryModel {
    /// The sheets that can lie on the library, topmost first. A question is put by the one on top, because a sheet
    /// under another cannot present.
    enum Layer { case root, preview, install, conflict }
    var topLayer: Layer { install != .closed ? .install : conflict != nil ? .conflict : preview != nil ? .preview : .root }
    func question(at layer: Layer) -> Binding<Confirm?> {
        Binding(get: { self.topLayer == layer ? self.confirm : nil }, set: { if $0 == nil, self.topLayer == layer { self.confirm = nil } })
    }
}

/// A quiet action beside the main ones: words in the app's own colour, no button around them.
struct LibraryQuietButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) { Text(title).font(.callout.weight(.medium)).foregroundStyle(enabled ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.tertiary)).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
}

/// The line at the bottom of the sheet: what is under way, a sync that failed, or what the last action did.
struct LibraryStatusStrip: View {
    @ObservedObject var model: HerdrLibraryModel

    static func words(_ work: HerdrLibraryModel.Work) -> String {
        switch work {
        case .syncing: HerdrLibraryCopy.syncing
        case .checking: HerdrLibraryCopy.checking
        case .updating: "Updating…"
        case .removing: "Removing…"
        case .looking: "Asking the repository what is new…"
        case .pulling: "Pulling from the repository…"
        case .pushing: "Sending to the repository…"
        case .bothWays: "Pulling, then pushing…"
        case .resolving: "Applying your choices…"
        case .sharing: "Sharing…"
        }
    }

    var body: some View {
        if model.work != nil || model.behind != nil || model.note != nil {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .center, spacing: 10) {
                    if let work = model.work {
                        ProgressView().controlSize(.small)
                        Text(Self.words(work)).font(.callout)
                        if work == .checking { Text(HerdrLibraryCopy.checkingDetail).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    } else if let behind = model.behind {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppColor.caution).accessibilityHidden(true)
                        Text(behind).font(.callout).textSelection(.enabled).lineLimit(2)
                    } else if let note = model.note {
                        Image(systemName: note.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(note.isProblem ? AppColor.caution : AppColor.good).accessibilityHidden(true)
                        Text(note.text).font(.callout).textSelection(.enabled).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28).padding(.vertical, 11)
            }
            .background(AppColor.raised.opacity(0.6))
        }
    }
}

/// A question before something that cannot be taken back or that leaves the server: a mark, what is asked, what
/// happens, and the two answers.
struct LibraryQuestion<Extra: View>: View {
    let symbol: String
    var colour: Color = AppColor.sand
    let title: String
    let detail: String
    let action: String
    var destructive = false
    let cancel: () -> Void
    let confirm: () -> Void
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        VStack(spacing: 18) {
            SymbolTile(symbol: symbol, colour: colour, size: 52)
            VStack(spacing: 8) {
                Text(title).font(.title2.bold()).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            extra()
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if destructive { Button(action, role: .destructive, action: confirm).buttonStyle(.borderedProminent).tint(.red) }
                else { Button(action, action: confirm).buttonStyle(.borderedProminent) }
            }
            .controlSize(.large).padding(.top, 2)
        }
        .padding(.horizontal, 32).padding(.vertical, 28).frame(width: 460).background(AppColor.panel)
    }
}

extension LibraryQuestion where Extra == EmptyView {
    init(symbol: String, colour: Color = AppColor.sand, title: String, detail: String, action: String, destructive: Bool = false, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.init(symbol: symbol, colour: colour, title: title, detail: detail, action: action, destructive: destructive, cancel: cancel, confirm: confirm) { EmptyView() }
    }
}

/// The question the library model has on the screen, in its words.
struct LibraryConfirmSheet: View {
    @ObservedObject var model: HerdrLibraryModel
    let question: HerdrLibraryModel.Confirm
    let server: HerdrServer

    var body: some View {
        switch question {
        case .remove(let item):
            LibraryQuestion(symbol: "trash.fill", colour: AppColor.clay, title: HerdrLibraryCopy.removeTitle(item), detail: HerdrLibraryCopy.removeDetail(item), action: "Remove", destructive: true, cancel: cancel, confirm: yes)
        case .push:
            LibraryQuestion(symbol: "arrow.up", colour: AppColor.sky, title: HerdrLibraryCopy.pushTitle(model.source), detail: HerdrLibraryCopy.pushDetail(model.source), action: "Commit and push", cancel: cancel, confirm: yes) { note }
        case .bothWays:
            LibraryQuestion(symbol: "arrow.up.arrow.down", colour: AppColor.sky, title: HerdrLibraryCopy.bothTitle, detail: HerdrLibraryCopy.bothDetail, action: "Pull and push", cancel: cancel, confirm: yes) { note }
        case .resolve:
            let count = model.conflict?.files.count ?? 0
            LibraryQuestion(symbol: "checkmark", colour: AppColor.sage, title: HerdrLibraryCopy.resolveTitle(count), detail: HerdrLibraryCopy.resolveDetail(count, push: model.conflict?.push ?? false), action: "Apply", cancel: cancel, confirm: yes)
        case .installAnyway(let names):
            let skills = (model.inspection?.skills ?? []).filter { names.contains($0.name) }
            LibraryQuestion(symbol: "exclamationmark.shield.fill", title: HerdrLibraryCopy.anywayTitle(names), detail: HerdrLibraryCopy.anywayDetail(skills), action: HerdrLibraryCopy.anyway, destructive: true, cancel: cancel, confirm: yes)
        case .share(let agent):
            LibraryQuestion(symbol: "person.badge.plus", colour: AppColor.sky, title: HerdrLibraryCopy.shareTitle(agent), detail: HerdrLibraryCopy.shareDetail(agent, server: server.name), action: "Share with \(agent)", cancel: cancel, confirm: yes)
        }
    }

    private func cancel() { model.confirm = nil }
    private func yes() { Task { await model.confirmed() } }

    /// The note that goes with what is saved to the repository.
    private var note: some View {
        StandaloneField(title: HerdrLibraryCopy.pushField, text: $model.message, prompt: HerdrLibraryCopy.pushPrompt).frame(maxWidth: .infinity)
    }
}
