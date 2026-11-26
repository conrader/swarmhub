import SwiftUI

// The Library area of a server's library (`HerdrLibrarySheet`): a search, a filter by kind with counts, and every
// thing as a row in the group that says where it stands; and what opens from a row: the thing itself to read, with
// the few actions the server offers for it, and what a sync would change in it.

/// Wraps its children onto as many lines as they need, like words.
struct LibraryFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = size(of: view, within: width)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = size(of: view, within: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
    private func size(of view: LayoutSubview, within width: CGFloat) -> CGSize {
        let ideal = view.sizeThatFits(.unspecified)
        guard ideal.width > width else { return ideal }
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

}

/// The Library area.
struct HerdrLibraryList: View {
    @ObservedObject var model: HerdrLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.phase {
            case .idle, .reading: StatusCard(kind: .working, title: "Reading the library…")
            case .unavailable(let why):
                StatusCard(kind: .warning, title: "The library could not be loaded", detail: why) { Button("Try again") { Task { await model.load() } }.padding(.top, 4) }
            case .older: StatusCard(kind: .info, title: HerdrLibraryCopy.olderService)
            case .ready:
                if let library = model.library {
                    if library.installed { ready(library) } else { StatusCard(kind: .warning, title: library.problem ?? HerdrLibraryCopy.notInstalled) }
                }
            }
        }
    }

    @ViewBuilder private func ready(_ library: HerdrLibrary) -> some View {
        toolbar(library)
        LibraryKindFilter(library: library, selection: $model.kind)
        let groups = library.groups(kind: model.kind, query: model.query)
        if groups.isEmpty {
            if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let kind = model.kind
                EmptyNote(symbol: kind?.symbol ?? "tray", title: kind.map { "No \($0.title.lowercased().replacingOccurrences(of: "mcp", with: "MCP")) yet" } ?? "Nothing here yet",
                          detail: Self.emptyDetail(kind), colour: kind?.colour ?? AppColor.olive).padding(.vertical, 8)
            } else {
                EmptyNote(symbol: "magnifyingglass", title: "Nothing matches “\(model.query.trimmingCharacters(in: .whitespacesAndNewlines))”", detail: "Try another word, or another kind.", colour: AppColor.olive).padding(.vertical, 8)
            }
        }
        ForEach(groups.map { $0.group }) { group in
            let items = groups.first { $0.group == group }?.items ?? []
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text("\(items.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
                    Spacer()
                    // "Update all" means all of them, so it shows only while all of them are on the screen.
                    if group == .update, library.updatable.count > 1, items.filter({ $0.can("update") }).count == library.updatable.count {
                        Button("Update all") { Task { await model.update(nil) } }.controlSize(.small).disabled(model.isBusy)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 54) }
                        LibraryItemRow(item: item) { Task { await model.open(item) } }
                    }
                }
                .background(AppColor.raised, in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
            }
        }
        if library.hiddenCount > 0 {
            Text("\(HerdrLibraryCopy.plural(library.hiddenCount, "more thing")) not listed here.").font(.caption).foregroundStyle(.secondary)
        }
    }

    static func emptyDetail(_ kind: HerdrLibraryKind?) -> String {
        switch kind {
        case nil: "Install skills from a repository to give your bots something to work with."
        case .skills?: "\(HerdrLibraryKind.skills.explained) Install some from a repository."
        case .agents?: "\(HerdrLibraryKind.agents.explained) They are added on the server, with skillshare."
        case .mcp?: "\(HerdrLibraryKind.mcp.explained) They are added on the server, with skillshare."
        case .plugins?: "\(HerdrLibraryKind.plugins.explained) They are added on the server, with skillshare."
        case .hooks?: "\(HerdrLibraryKind.hooks.explained) They are added on the server, with skillshare."
        }
    }

    private func toolbar(_ library: HerdrLibrary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search the library", text: $model.query, prompt: Text("Search")).textFieldStyle(.plain).labelsHidden()
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(width: 240).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Spacer(minLength: 8)
            if model.work != .checking, let checked = HerdrLibraryCopy.lastChecked(library, now: model.now()) {
                Text(checked).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button { Task { await model.check() } } label: { Label("Check for updates", systemImage: "arrow.clockwise") }.disabled(model.isBusy)
            Button { model.startInstall() } label: { Label("Install…", systemImage: "plus") }.buttonStyle(.appleProminent).disabled(model.isBusy)
        }
        .controlSize(.large)
    }
}

/// The filter by kind: every kind as a rounded button with its count, and all of them first.
struct LibraryKindFilter: View {
    let library: HerdrLibrary
    @Binding var selection: HerdrLibraryKind?

    var body: some View {
        LibraryFlow(spacing: 8) {
            chip(nil, title: "All", symbol: "square.grid.2x2.fill", count: library.total)
            ForEach(HerdrLibraryKind.allCases) { kind in chip(kind, title: kind.title, symbol: kind.symbol, count: library.count(of: kind)) }
        }
    }

    private func chip(_ kind: HerdrLibraryKind?, title: String, symbol: String, count: Int?) -> some View {
        let selected = selection == kind
        return Button { selection = kind } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .medium))
                Text(count.map(String.init) ?? "?").font(.caption.weight(.semibold)).opacity(selected ? 0.85 : 0.55)
            }
            .foregroundStyle(selected ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(AppColor.raised), in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(selected ? 0 : 0.06), lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count.map(String.init) ?? "not read")").accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// One thing in the list: its kind's tile, its name as people read it, one line about it and where it stands.
struct LibraryItemRow: View {
    let item: HerdrLibraryItem
    let open: () -> Void

    var body: some View {
        let off = item.state == .off
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                SymbolTile(symbol: item.known?.symbol ?? "questionmark", colour: off ? Color.gray.opacity(0.55) : (item.known?.colour ?? AppColor.olive), size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.readable).font(.system(size: 13, weight: .semibold)).foregroundStyle(off ? .secondary : .primary).lineLimit(1)
                    Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                LibraryStateChip(state: item.state)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(item.name)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }

    /// What it does, in its own words; without any, what kind of thing it is and where it came from.
    private var line: String {
        if let description = item.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty { return description }
        let kind = item.known?.noun.withCapital ?? item.kind
        return HerdrLibraryCopy.origin(item).map { "\(kind) · \($0)" } ?? kind
    }
}

/// One thing opened: what it is, the few things that can be done with it, and what there is to read. A skill shows
/// its `SKILL.md` as a page with its other files to choose from; an MCP server, a plugin or a hook shows its
/// settings, with secrets as names only.
struct HerdrLibraryPreviewSheet: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var model: HerdrLibraryModel
    var server: HerdrServer? = nil
    var height: CGFloat = HerdrLibraryPreviewSheet.size.height
    static let size = CGSize(width: 720, height: 660)

    var body: some View {
        VStack(spacing: 0) {
            if let preview = model.preview {
                let item = model.current(preview.item)
                header(item)
                actions(item)
                Divider()
                ScrollView { content(item, preview).padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .topLeading) }
            }
        }
        .frame(width: Self.size.width, height: height).background(AppColor.panel)
        .sheet(item: model.question(at: .preview)) { question in
            LibraryConfirmSheet(model: model, question: question, server: server ?? store.herdrServers[0])
        }
        .sheet(isPresented: Binding(get: { model.diff != nil }, set: { if !$0 { model.closeDiff() } })) { HerdrLibraryDiffSheet(model: model) }
    }

    private func header(_ item: HerdrLibraryItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolTile(symbol: item.known?.symbol ?? "questionmark", colour: item.known?.colour ?? AppColor.olive, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.readable).font(.title2.bold()).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                if let description = item.description, !description.isEmpty {
                    Text(description).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                LibraryFlow(spacing: 6) {
                    LibraryStateChip(state: item.state)
                    FactChip(text: item.known?.noun.withCapital ?? item.kind)
                    if let origin = HerdrLibraryCopy.origin(item) { FactChip(text: origin) }
                    if let version = item.version, !version.isEmpty { FactChip(text: "Version \(version)") }
                }.padding(.top, 4)
            }
            Spacer(minLength: 8)
            Button("Done") { model.closePreview() }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 14)
    }

    /// The actions the server offers for this thing, and for the kinds it offers none for, where they are changed.
    @ViewBuilder private func actions(_ item: HerdrLibraryItem) -> some View {
        HStack(alignment: .center, spacing: 10) {
            if item.canSwitch {
                let on = model.isOn(item)
                Toggle(isOn: Binding(get: { on }, set: { model.set(item, on: $0) })) { Text(on ? "On for your bots" : "Off").font(.callout.weight(.medium)) }
                    .toggleStyle(.appleSwitchLabelled).disabled(model.work != nil)
                if model.isChanging(item) || model.work == .syncing { ProgressView().controlSize(.small) }
            } else if item.actions.isEmpty {
                Label(Self.handled(item), systemImage: "info.circle").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if item.can("update"), item.state == .update {
                Button { Task { await model.update(item) } } label: { Label("Update", systemImage: "arrow.down.circle") }.buttonStyle(.appleProminent).disabled(model.isBusy)
            }
            if item.can("diff") { Button("Show changes") { Task { await model.showDiff(item) } }.disabled(model.work != nil) }
            if item.can("uninstall") { Button("Remove…", role: .destructive) { model.ask(.remove(item)) }.disabled(model.isBusy) }
        }
        .padding(.horizontal, 24).padding(.bottom, 14)
    }

    static func handled(_ item: HerdrLibraryItem) -> String {
        let kind = item.known?.title ?? "These"
        return "\(kind) are added and changed on the server, with skillshare. A sync brings them to your AIs."
    }

    @ViewBuilder private func content(_ item: HerdrLibraryItem, _ preview: HerdrLibraryModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if let waiting = HerdrLibraryCopy.waitingLine(item) {
                Label(waiting, systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(AppColor.caution).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = preview.problem { StatusCard(kind: .warning, title: "This could not be read", detail: problem) }
            if let loaded = preview.loaded {
                if loaded.settings.isEmpty { LibraryPreviewFile(model: model, loaded: loaded, loading: preview.loading) } else { LibraryPreviewSettings(loaded: loaded, said: item.description) }
                if !loaded.targets.isEmpty {
                    SettingBlock(title: "Where it goes") {
                        LibraryFlow(spacing: 6) { ForEach(loaded.targets) { place in LibraryPlaceChip(place: place) } }
                    }
                }
            } else if preview.loading { StatusCard(kind: .working, title: "Reading…") }
        }
    }
}

/// One AI a thing goes to, with what waits there.
private struct LibraryPlaceChip: View {
    let place: HerdrLibraryPreview.Place
    var body: some View {
        let text = "\(place.name) · \(HerdrLibraryCopy.place(place))"
        switch place.state {
        case "waiting": FactChip(text: text, symbol: "arrow.triangle.2.circlepath", colour: AppColor.caution)
        case "in_sync": FactChip(text: text, symbol: "checkmark", colour: AppColor.good)
        default: FactChip(text: text)
        }
    }
}

/// A skill's or an agent's file: the other files to choose from, what its front matter says, and the file itself.
private struct LibraryPreviewFile: View {
    @ObservedObject var model: HerdrLibraryModel
    let loaded: HerdrLibraryPreview
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if loaded.files.count > 1 { files }
            if !loaded.facts.isEmpty {
                LibraryFlow(spacing: 6) { ForEach(loaded.facts) { fact in FactChip(text: "\(HerdrLibraryCopy.readable(fact.key)): \(fact.value.text)") } }
            }
            VStack(alignment: .leading, spacing: 12) {
                if let text = loaded.text {
                    if loaded.isMarkdown { MarkdownContent(message: ChatMessage(role: .assistant, content: HerdrLibraryCopy.page(text))) }
                    else { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                } else {
                    Text(HerdrLibraryCopy.notText).font(.callout).foregroundStyle(.secondary)
                }
                if loaded.truncated { Label(HerdrLibraryCopy.truncated, systemImage: "scissors").font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(AppColor.card, in: RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: AppleMetrics.corner, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1) }
            .opacity(loading ? 0.5 : 1)
        }
    }

    /// A few files are a gallery of tiles; many are a pop-up, so the page stays the main thing.
    @ViewBuilder private var files: some View {
        let chosen = loaded.file ?? loaded.files.first ?? ""
        if loaded.files.count <= 9 {
            TileGallery(items: loaded.files.map { NamedChoice(id: $0, name: $0) }, minimum: 150, isSelected: { $0.id == chosen }, name: \.name, select: { file in Task { await model.show(file: file.id) } }) { file in
                NameTile(name: file.name, symbol: file.name.lowercased().hasSuffix(".md") ? "doc.richtext" : "doc.text")
            }
        } else {
            HStack(spacing: 10) {
                Picker("File", selection: Binding(get: { chosen }, set: { file in Task { await model.show(file: file) } })) {
                    ForEach(loaded.files, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(maxWidth: 320)
                Text(HerdrLibraryCopy.plural(loaded.fileCount ?? loaded.files.count, "file")).font(.callout).foregroundStyle(.secondary)
            }
        }
        if loaded.hiddenFiles > 0 { Text(HerdrLibraryCopy.moreFiles(loaded.hiddenFiles)).font(.caption).foregroundStyle(.secondary) }
    }
}

/// The settings of an MCP server, a plugin or a hook: each under a heading in plain words. A secret shows the names
/// of what is kept, each with a lock, and never a value.
private struct LibraryPreviewSettings: View {
    let loaded: HerdrLibraryPreview
    /// The description the header already shows.
    var said: String? = nil

    private var merged: [HerdrLibraryPreview.Fact] { HerdrLibraryCopy.settings(loaded.settings, said: said) }

    var body: some View {
        let facts = merged
        VStack(alignment: .leading, spacing: 20) {
            // The first secret says once that only names are shown.
            let firstHidden = facts.first(where: \.hidden)?.id
            ForEach(facts) { fact in
                SettingBlock(title: HerdrLibraryCopy.setting(fact.key), detail: fact.id == firstHidden ? HerdrLibraryCopy.keptOnServer : nil) { value(fact) }
            }
            if facts.isEmpty { Text("The server lists no settings for it.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func value(_ fact: HerdrLibraryPreview.Fact) -> some View {
        let parts = fact.value.parts
        if fact.hidden {
            LibraryFlow(spacing: 6) { ForEach(Array(parts.enumerated()), id: \.offset) { _, part in FactChip(text: part, symbol: "lock.fill", colour: AppColor.olive) } }
        } else if ["command", "url", "args"].contains(fact.key) {
            Text(parts.joined(separator: " ")).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if parts.count > 1, parts.allSatisfy({ $0.count <= 28 }) {
            LibraryFlow(spacing: 6) { ForEach(Array(parts.enumerated()), id: \.offset) { _, part in FactChip(text: part) } }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in Text(part).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// What a sync would change in one thing, as skillshare prints it: added lines green, removed lines red.
struct HerdrLibraryDiffSheet: View {
    @ObservedObject var model: HerdrLibraryModel
    static let size = CGSize(width: 760, height: 600)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.diff?.edits == true ? "Edited since it was installed" : "What a sync changes").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Text(model.diff?.title ?? "").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let diff = model.diff, diff.offersEdits, let item = diff.item {
                    SegmentedChoice(title: "Which changes", options: [(false, "A sync"), (true, "My edits")],
                                    selection: Binding(get: { diff.edits }, set: { edits in Task { await model.showDiff(item, edits: edits) } })).frame(width: 200).disabled(diff.loading)
                }
                Button("Done") { model.closeDiff() }.keyboardShortcut(.defaultAction).controlSize(.large)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            Group {
                if let diff = model.diff {
                    if diff.loading { StatusCard(kind: .working, title: "Comparing…").padding(24) }
                    else if let problem = diff.problem { StatusCard(kind: .warning, title: "The changes could not be shown", detail: problem).padding(24) }
                    else if (diff.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        EmptyNote(symbol: "equal", title: diff.edits ? "Not edited" : "Nothing would change", detail: diff.edits ? "It is as it was installed." : "Your AIs already have it as the library has it.").padding(24)
                    } else { lines(diff.text ?? "") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.size.width, height: Self.size.height).background(AppColor.panel)
    }

    private func lines(_ text: String) -> some View {
        let all = text.components(separatedBy: "\n"), shown = Array(all.prefix(3_000))
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Self.colour(line)).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 1).frame(maxWidth: .infinity, alignment: .leading).background(Self.wash(line))
                }
                if all.count > shown.count { Text("The rest is not shown.").font(.caption).foregroundStyle(.secondary).padding(14) }
            }
            .padding(.vertical, 12).frame(minWidth: Self.size.width, alignment: .leading)
        }
        .background(AppColor.card)
    }

    static func colour(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") || line.hasPrefix("diff ") { return .secondary }
        if line.hasPrefix("+") { return AppColor.good }
        if line.hasPrefix("-") { return AppColor.caution }
        return .primary
    }
    static func wash(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return AppColor.sage.opacity(0.14) }
        if line.hasPrefix("-") { return AppColor.clay.opacity(0.14) }
        return .clear
    }
}
