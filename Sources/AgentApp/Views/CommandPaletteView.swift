import SwiftUI

/// The quick switcher (⌘K): the first match is highlighted, up and down move the highlight, Return opens it,
/// Escape closes the sheet.
struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    let selectCommand: (AppCommand) -> Void
    let openSetup: () -> Void
    @State private var query: String
    @State private var model = QuickSwitcherModel()
    @State private var archiveFiles = QuickSwitcherModel.ArchiveFiles()
    @State private var searching = false
    @State private var keyboardPointer: NSPoint?
    @FocusState private var searchFocused: Bool
    init(query: String = "", selectCommand: @escaping (AppCommand) -> Void, openSetup: @escaping () -> Void) {
        _query = State(initialValue: query); self.selectCommand = selectCommand; self.openSetup = openSetup
    }
    var body: some View {
        ScrollViewReader { proxy in
            content(proxy)
        }
    }

    private func content(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats, messages and actions", text: $query).textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1, proxy: proxy); return .handled }
                    .onKeyPress(.upArrow) { move(-1, proxy: proxy); return .handled }
                    .onSubmit { if let item = model.selection { perform(item) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            List {
                let items = model.items
                if items.isEmpty {
                    if searching { ProgressView("Searching messages…").controlSize(.small).padding() }
                    else { Text("No matches").foregroundStyle(.secondary).padding() }
                }
                ForEach(items.filter { !$0.isCommand }) { row($0) }
                if items.contains(where: \.isCommand) { Divider() }
                ForEach(items.filter(\.isCommand)) { row($0) }
            }.listStyle(.plain).scrollContentBackground(.hidden).id(query)
        }.frame(width: 480, height: 380).background(AppColor.panel)
        .task { searchFocused = true }
        .task(id: query) { [query] in
            guard !Task.isCancelled else { return }
            searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            keyboardPointer = NSEvent.mouseLocation
            let navigation = QuickSwitcherModel.items(in: store, query: query)
            model.update(navigation)
            if searching {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            let messages = await QuickSwitcherModel.messages(in: store, query: query, files: archiveFiles) { live in
                if !Task.isCancelled { show(live, with: navigation) }
            }
            guard !Task.isCancelled else { return }
            if !messages.isEmpty { show(messages, with: navigation) }
            searching = false
        }
    }

    private func show(_ messages: [QuickSwitcherModel.Item], with navigation: [QuickSwitcherModel.Item]) {
        let selected = model.highlighted
        model.update(navigation.filter { !$0.isCommand } + messages + navigation.filter(\.isCommand))
        if let selected { model.highlight(selected) }
    }

    private func move(_ offset: Int, proxy: ScrollViewProxy) {
        keyboardPointer = NSEvent.mouseLocation
        model.move(by: offset)
        if let id = model.highlighted { proxy.scrollTo(id) }
    }

    private func row(_ item: QuickSwitcherModel.Item) -> some View {
        Button { perform(item) } label: {
            HStack {
                Image(systemName: item.icon).frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    title(for: item).lineLimit(2).multilineTextAlignment(.leading)
                    if let detail = item.detail { Text(detail).font(.caption).lineLimit(1) }
                }
                Spacer()
                if let shortcut = item.shortcut { Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }.padding(9).contentShape(Rectangle())
            .foregroundStyle(model.highlighted == item.id ? AnyShapeStyle(AppColor.onAccent) : AnyShapeStyle(.primary))
            .background(model.highlighted == item.id ? AnyShapeStyle(TintShapeStyle()) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!item.isEnabled).id(item.id)
        .accessibilityAddTraits(model.highlighted == item.id ? .isSelected : [])
        .onContinuousHover { phase in
            // Scrolling a keyboard selection can move another row beneath a stationary pointer.
            guard case .active = phase, NSEvent.mouseLocation != keyboardPointer else { return }
            keyboardPointer = nil
            if model.highlighted != item.id { model.highlight(item.id) }
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden).listRowBackground(Color.clear)
    }

    private func title(for item: QuickSwitcherModel.Item) -> Text {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .message = item.target, !term.isEmpty,
              let match = item.title.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) else {
            return Text(verbatim: item.title)
        }
        var text = AttributedString(item.title)
        if let range = Range(match, in: text) { text[range].inlinePresentationIntent = .stronglyEmphasized }
        return Text(text)
    }

    private func perform(_ item: QuickSwitcherModel.Item) {
        guard item.isEnabled else { return }
        switch item.target {
        case .bot(let id): if let bot = store.bots.first(where: { $0.id == id }) { store.open(bot) }
        case .group(let id): if let group = store.groups.first(where: { $0.id == id }) { store.open(group) }
        case .message(let location):
            if let group = store.groups.first(where: { $0.id == location.conversation }) { store.open(group) }
            else if let bot = store.bots.first(where: { $0.id == location.conversation }) { store.open(bot) }
            store.scrollTarget = location
        case .command(let command): selectCommand(command)
        case .setup: openSetup()
        }
        dismiss()
    }
}
