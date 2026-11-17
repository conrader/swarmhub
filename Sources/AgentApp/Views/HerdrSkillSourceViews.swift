import SwiftUI

// The quieter parts of a server's library: the Git repository the library is kept in (its state in words, pull,
// commit and push, sync both ways, and the choice per file when both sides changed the same one), skillshare on
// every server the app knows (the Servers area), and the choice between the library all bots share and a
// project's own.

/// The library's repository, at the bottom of the Overview: its state in a few words, and the three things to do.
struct HerdrLibrarySourceCard: View {
    @ObservedObject var model: HerdrLibraryModel
    let source: HerdrLibrarySource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupHeading(title: HerdrLibraryCopy.sourceTitle, detail: "Where your library is kept, so it has a history and can be shared between servers.")
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    SymbolTile(symbol: "arrow.triangle.branch", colour: AppColor.olive, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(HerdrLibraryCopy.source(source)).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(source.problem ?? HerdrLibraryCopy.sourceDetail(source)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if source.repo {
                    HStack(spacing: 8) {
                        Button(HerdrLibraryCopy.pull) { Task { await model.pull() } }.disabled(!source.hasRemote)
                        Button(HerdrLibraryCopy.push) { model.ask(.push) }.disabled(!source.hasRemote || (source.unsaved == 0 && source.toPush == 0))
                        Button(HerdrLibraryCopy.both) { model.ask(.bothWays) }.disabled(!source.hasRemote)
                        Spacer(minLength: 8)
                        LibraryQuietButton(title: "Look for changes") { Task { await model.lookAtSource() } }.disabled(!source.hasRemote)
                    }
                    .disabled(model.isBusy)
                }
            }
            .appleCard(padding: 14)
        }
    }
}

/// Both sides changed the same files: each file's two versions side by side, and a choice per file. Nothing changes
/// until every file has one and Apply was confirmed.
struct HerdrLibraryConflictSheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryModel
    static let size = CGSize(width: 940, height: 680)

    var body: some View {
        let files = model.conflict?.files ?? []
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                SymbolTile(symbol: "arrow.triangle.merge", colour: AppColor.sand, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(HerdrLibraryCopy.conflictTitle).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text(HerdrLibraryCopy.conflictDetail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let note = model.note, note.isProblem { StatusCard(kind: .warning, title: note.text) }
                    ForEach(files) { file in LibraryConflictFile(model: model, file: file) }
                }
                .padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider()
            HStack(spacing: 12) {
                Button("Cancel") { model.closeConflict() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.work == .resolving { ProgressView().controlSize(.small) }
                Text("\(files.filter { model.choices[$0.path] != nil }.count) of \(files.count) chosen").font(.callout).foregroundStyle(.secondary)
                Button("Apply…") { model.ask(.resolve) }.buttonStyle(.borderedProminent).disabled(!model.conflictDecided || model.isBusy)
            }
            .controlSize(.large).padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: Self.size.width, height: Self.size.height).background(AppColor.panel)
        .sheet(item: model.question(at: .conflict)) { question in LibraryConfirmSheet(model: model, question: question, server: store.herdrServers[0]) }
    }
}

/// One file of a conflict: its path, and its two versions to choose between.
private struct LibraryConflictFile: View {
    @ObservedObject var model: HerdrLibraryModel
    let file: HerdrSourceAnswer.Conflict.File

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(file.path).font(.system(.headline, design: .monospaced)).textSelection(.enabled)
                if file.cut == true { FactChip(text: HerdrLibraryCopy.cut, symbol: "scissors") }
            }
            HStack(alignment: .top, spacing: 12) {
                side("mine", title: HerdrLibraryCopy.mine, symbol: "server.rack", text: file.mine, deleted: HerdrLibraryCopy.deletedMine)
                side("theirs", title: HerdrLibraryCopy.theirs, symbol: "arrow.triangle.branch", text: file.theirs, deleted: HerdrLibraryCopy.deletedTheirs)
            }
        }
    }

    private func side(_ side: String, title: String, symbol: String, text: String?, deleted: String) -> some View {
        let chosen = model.choices[file.path] == side
        return VStack(alignment: .leading, spacing: 0) {
            Button { model.choose(file.path, side) } label: {
                HStack(spacing: 8) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
                        .foregroundStyle(chosen ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.tertiary)).accessibilityHidden(true)
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(chosen ? "Kept" : "Keep this one").font(.caption.weight(.medium)).foregroundStyle(chosen ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Keep the version of \(title.lowercased()) for \(file.path)").accessibilityAddTraits(chosen ? [.isSelected, .isButton] : .isButton)
            Divider()
            if let text {
                ScrollView {
                    Text(text.isEmpty ? " " : text).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                }
                .frame(height: 170)
            } else {
                Label(deleted, systemImage: "trash").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 170, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity)
        .background(AppColor.raised, in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous).strokeBorder(chosen ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(Color.primary.opacity(0.06)), lineWidth: chosen ? 2 : 1) }
    }
}

/// The Servers area: skillshare on every server the app knows, one card each.
struct HerdrLibraryServers: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryServersModel
    /// The server whose library this sheet is.
    let current: HerdrServer
    /// Renders show servers of their own.
    var shown: [HerdrServer]? = nil

    var body: some View {
        let servers = shown ?? store.herdrServers
        VStack(alignment: .leading, spacing: 14) {
            GroupHeading(title: "Servers", detail: "Every server keeps a library of its own. This is how skillshare is doing on each of yours.")
            ForEach(servers) { server in
                LibraryServerCard(server: server, state: model.state(for: server), isCurrent: server.id == current.id && servers.count > 1,
                                  check: { Task { await model.check(server) } }, upgrade: { model.confirming = server.id })
            }
        }
        .task { if store.launchWorkEnabled { await model.load(servers) } }
        .sheet(isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } })) {
            if let server = servers.first(where: { $0.id == model.confirming }) { HerdrLibraryUpgradeQuestion(model: model, server: server) }
        }
    }
}

/// The question before skillshare itself is replaced on a server.
struct HerdrLibraryUpgradeQuestion: View {
    @ObservedObject var model: HerdrLibraryServersModel
    let server: HerdrServer
    var body: some View {
        LibraryQuestion(symbol: "arrow.down.circle.fill", colour: AppColor.sky, title: HerdrLibraryCopy.upgradeTitle(server.name), detail: HerdrLibraryCopy.upgradeDetail(model.state(for: server)?.machine),
                        action: "Update skillshare", cancel: { model.confirming = nil }, confirm: { Task { await model.upgrade(server) } })
    }
}

/// One server: where it is, and in a few sentences how skillshare is doing there.
struct LibraryServerCard: View {
    let server: HerdrServer
    let state: HerdrLibraryServersModel.State?
    var isCurrent = false
    let check: () -> Void
    let upgrade: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                SymbolTile(symbol: server.kind.mark.symbol, colour: server.kind.mark.colour, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(server.name).font(.headline)
                        if isCurrent { FactChip(text: "This library") }
                    }
                    if server.place != server.name { Text(server.place).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if let machine = state?.machine, machine.installed, state?.phase == .ready { FactChip(text: HerdrLibraryCopy.version(machine)) }
                if state?.working == true { ProgressView().controlSize(.small) }
            }
            switch state?.phase {
            case nil, .reading?: line("hourglass", "Asking \(server.name)…", colour: nil)
            case .older?: line("arrow.up.circle.fill", HerdrLibraryCopy.serverOlder, colour: AppColor.sky)
            case .unreachable(let why)?: line("exclamationmark.triangle.fill", why, colour: AppColor.caution)
            case .ready?: if let machine = state?.machine { ready(machine) }
            }
            if let note = state?.note {
                line(state?.noteIsProblem == true ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", note, colour: state?.noteIsProblem == true ? AppColor.caution : AppColor.good)
            }
        }
        .appleCard(padding: 16)
    }

    @ViewBuilder private func ready(_ machine: HerdrLibraryMachine) -> some View {
        if !machine.installed {
            line("questionmark.circle.fill", machine.problem ?? HerdrLibraryCopy.notInstalled, colour: nil)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                let behind = machine.waitingCount > 0 || machine.targets.isEmpty
                line(behind ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill", HerdrLibraryCopy.machineWaiting(machine), colour: behind ? AppColor.caution : AppColor.good)
                if let source = machine.source { line("arrow.triangle.branch", source.problem ?? HerdrLibraryCopy.machineSource(source), colour: nil) }
                if let problem = machine.problem, !problem.isEmpty { line("exclamationmark.triangle.fill", problem, colour: AppColor.caution) }
                ForEach(machine.warnings) { note in
                    line("exclamationmark.triangle.fill", ([note.message ?? ""] + (note.details ?? [])).filter { !$0.isEmpty }.joined(separator: " "), colour: AppColor.caution)
                }
            }
            if machine.updateAvailable == true {
                HStack(alignment: .center, spacing: 10) {
                    line("arrow.down.circle.fill", HerdrLibraryCopy.newer(machine), colour: AppColor.sky)
                    Spacer(minLength: 8)
                    Button("Update skillshare…", action: upgrade).disabled(state?.working == true)
                }
            } else {
                LibraryQuietButton(title: "Look for a newer skillshare", action: check).disabled(state?.working == true)
            }
        }
    }

    private func line(_ symbol: String, _ text: String, colour: Color?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(colour.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary)).frame(width: 18).accessibilityHidden(true)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Whose library a bot's Skills show: the one all bots on the server share, or the own library of one of the bot's
/// projects. Offered only when such a project exists on the server itself.
struct HerdrLibraryScopePicker: View {
    let server: HerdrServer
    let choices: [HerdrLibraryScope.Choice]
    /// The chosen project's folder; nil for the shared library.
    let selection: String?
    let select: (String?) -> Void

    var body: some View {
        SettingBlock(title: "Which library") {
            VStack(spacing: 8) {
                let all = HerdrLibraryCopy.scopeAll(server.name)
                OptionCard(symbol: "person.3.fill", colour: AppColor.sage, title: all.title, detail: all.detail, selected: selection == nil, select: { select(nil) })
                ForEach(choices) { choice in
                    let words = HerdrLibraryCopy.scopeProject(choice)
                    OptionCard(symbol: "folder.fill", colour: AppColor.sky, title: words.title, detail: words.detail, selected: selection == choice.folder, select: { select(choice.folder) })
                }
            }
        }
    }
}
