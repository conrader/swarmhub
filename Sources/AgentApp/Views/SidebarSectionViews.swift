import SwiftUI

/// Which name prompt is open: a new section (with the chat to put in it, if the prompt came from a chat's menu) or a rename.
enum SidebarSectionPrompt: Identifiable, Equatable {
    case new(UUID?), rename(UUID)
    var id: String {
        switch self {
        case .new(let chat): "new:\(chat?.uuidString ?? "-")"
        case .rename(let section): "rename:\(section.uuidString)"
        }
    }
}

/// A section's header: the whole line folds and unfolds it, with no animation. Folded, it shows how many chats it holds
/// and a dot when one is unread. The menu renames, moves and deletes the section (Unsectioned has none of these).
struct SidebarSectionHeader: View {
    @EnvironmentObject private var store: AppStore
    let bucket: SidebarLayout.Bucket
    let askRename: (UUID) -> Void
    let askDelete: (UUID) -> Void

    var body: some View {
        let count = bucket.chats.count
        Button { store.setSidebarSectionCollapsed(bucket.id, !bucket.isCollapsed) } label: {
            HStack(spacing: 6) {
                Image(systemName: bucket.isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                Text(bucket.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if bucket.isCollapsed {
                    Text("\(count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                    if bucket.hasUnread { Circle().fill(.tint).frame(width: 6, height: 6).accessibilityHidden(true) }
                }
            }.foregroundStyle(.secondary).padding(.horizontal, SidebarMetrics.rowPadding).frame(height: SidebarMetrics.sectionHeader).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(bucket.isCollapsed ? "Show \(bucket.name)" : "Hide \(bucket.name)")
            .accessibilityLabel("\(bucket.name), \(count) \(count == 1 ? "chat" : "chats")")
            .accessibilityValue(bucket.isCollapsed ? Text(verbatim: "folded") : Text(verbatim: "open"))
            .accessibilityAddTraits(.isHeader)
            .contextMenu {
                if let id = bucket.id {
                    let index: Int? = store.sidebar.sections.firstIndex { $0.id == id }
                    Button("Rename…", systemImage: "pencil") { askRename(id) }
                    Button("Move Up", systemImage: "arrow.up") { store.moveSidebarSection(id, by: -1) }.disabled(index == nil || index == 0)
                    Button("Move Down", systemImage: "arrow.down") { store.moveSidebarSection(id, by: 1) }
                        .disabled(index == nil || index == store.sidebar.sections.count - 1)
                    Divider()
                    Button("Delete Section…", systemImage: "trash", role: .destructive) { askDelete(id) }
                }
            }
    }
}

/// The quiet line under a header whose section holds no chats yet.
struct SidebarEmptySectionLine: View {
    var body: some View {
        Text("No chats yet").font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(.horizontal, SidebarMetrics.rowPadding).frame(height: 28, alignment: .leading)
    }
}

/// The name prompt (new section, rename) and the delete confirmation for a section that still has chats.
struct SidebarSectionPrompts: ViewModifier {
    @EnvironmentObject private var store: AppStore
    @Binding var prompt: SidebarSectionPrompt?
    @Binding var sectionToDelete: UUID?
    @State private var text = ""

    private var title: String {
        if case .rename? = prompt { return "Rename section" }
        return "New section"
    }

    private func commit() {
        guard let prompt else { return }
        switch prompt {
        case .new(let chat): store.createSidebarSection(named: text, adding: chat)
        case .rename(let id): store.renameSidebarSection(id, to: text)
        }
    }

    private var nameIsValid: Bool {
        var excluded: UUID? = nil
        if case .rename(let id)? = prompt { excluded = id }
        return store.sidebar.validatedName(text, excluding: excluded) != nil
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: prompt) { _, new in
                guard let new else { return }
                switch new {
                case .new: text = ""
                case .rename(let id): text = store.sidebar.section(id)?.name ?? ""
                }
            }
            .alert(title, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) { prompt = nil }
                Button(title == "New section" ? "Create" : "Rename") { commit(); prompt = nil }.disabled(!nameIsValid)
            } message: { Text("Up to 48 characters. \"Pinned\" and \"Unsectioned\" are taken.") }
            .alert("Delete section \(sectionToDelete.flatMap { store.sidebar.section($0)?.name } ?? "")?",
                   isPresented: Binding(get: { sectionToDelete != nil }, set: { if !$0 { sectionToDelete = nil } })) {
                Button("Cancel", role: .cancel) { sectionToDelete = nil }
                Button("Delete Section", role: .destructive) { if let sectionToDelete { store.deleteSidebarSection(sectionToDelete) }; sectionToDelete = nil }
            } message: { Text("Its chats move to Unsectioned. No chat is deleted.") }
    }
}
