import SwiftUI

/// The quick switcher (⌘K). P32 4: the first match is highlighted, up and down move the highlight, Return opens it,
/// Escape closes the sheet.
struct CommandPaletteView: View {
    @EnvironmentObject private var store: AppStore; @Environment(\.dismiss) private var dismiss
    let selectCommand: (AppCommand) -> Void
    let openSetup: () -> Void
    /// P34: a thread row; opened after the switcher closes (nil: at once).
    var openThread: ((BotThreadKey) -> Void)?
    @State private var query: String
    @State private var model = QuickSwitcherModel()
    @FocusState private var searchFocused: Bool
    init(query: String = "", selectCommand: @escaping (AppCommand) -> Void, openSetup: @escaping () -> Void, openThread: ((BotThreadKey) -> Void)? = nil) {
        _query = State(initialValue: query); self.selectCommand = selectCommand; self.openSetup = openSetup; self.openThread = openThread
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to an agent or action", text: $query).textFieldStyle(.plain).font(.title3).focused($searchFocused)
                    .onKeyPress(.downArrow) { model.move(by: 1); return .handled }
                    .onKeyPress(.upArrow) { model.move(by: -1); return .handled }
                    .onSubmit { if let item = model.selection { perform(item) } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView { VStack(spacing: 4) {
                    let items = model.items
                    ForEach(items.filter { !$0.isCommand }) { row($0) }
                    if items.contains(where: \.isCommand) { Divider().padding(.vertical, 4) }
                    ForEach(items.filter(\.isCommand)) { row($0) }
                }.padding(8) }
                .onChange(of: model.highlighted) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }.frame(width: 480, height: 380).background(AppColor.panel)
        .onAppear { model.update(QuickSwitcherModel.items(in: store, query: query)); searchFocused = true }
        .onChange(of: query) { _, query in model.update(QuickSwitcherModel.items(in: store, query: query)) }
    }

    private func row(_ item: QuickSwitcherModel.Item) -> some View {
        Button { perform(item) } label: {
            HStack {
                if case .botThread(let key) = item.target {
                    HStack(spacing: -5) { BotMark(profile: key.from, size: 18); BotMark(profile: key.to, size: 18) }.frame(width: 24)
                } else { Image(systemName: item.icon).frame(width: 24) }
                Text(item.title); Spacer()
                if let shortcut = item.shortcut { Text(shortcut).font(.caption.monospaced()).foregroundStyle(.secondary) }
            }.padding(9).contentShape(Rectangle())
            .background(model.highlighted == item.id ? AppColor.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).disabled(!item.isEnabled).id(item.id)
        .onHover { if $0 { model.highlight(item.id) } }
    }

    private func perform(_ item: QuickSwitcherModel.Item) {
        guard item.isEnabled else { return }
        switch item.target {
        case .bot(let id): if let bot = store.bots.first(where: { $0.id == id }) { store.open(bot) }
        case .group(let id): if let group = store.groups.first(where: { $0.id == id }) { store.open(group) }
        case .command(let command): selectCommand(command)
        case .setup: openSetup()
        case .botThread(let key): if let openThread { openThread(key) } else { store.openThread(key) }
        }
        dismiss()
    }
}
