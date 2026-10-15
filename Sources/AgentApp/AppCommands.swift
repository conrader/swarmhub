import AppKit
import SwiftUI

/// The agent panel's tabs in bar order (P33). Members folded into the bottom of Overview; `AppCommand.members` (⌘5) opens
/// Overview so the old shortcut still lands on them.
enum AgentInfoTab: String, CaseIterable {
    case overview = "Overview", model = "Model", skills = "Skills", activity = "Activity", routines = "Routines", media = "Media", computer = "Computer"
}

/// Menu items, the quick switcher and the shortcut reference share the same actions and bindings.
enum AppCommand: String, CaseIterable, Identifiable {
    case settings, newAgent, newGroup, importTemplate, quickSwitcher
    case toggleSidebar, toggleInfo, hiddenChats
    case overview, routines, media, computer, members, model, skills, activity
    case previousChat, nextChat, backToChat, agentSettings, openComputer, stopResponse, keyboardShortcuts

    var id: Self { self }
    var title: String {
        switch self {
        case .settings: "Settings…"
        case .newAgent: "New Agent…"
        case .newGroup: "New Group…"
        case .importTemplate: "Import Template…"
        case .quickSwitcher: "Quick Switcher…"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleInfo: "Toggle Agent Info"
        case .hiddenChats: "Toggle Hidden Chats"
        case .overview: "Overview"
        case .routines: "Routines"
        case .media: "Media"
        case .computer: "Computer"
        case .members: "Members"
        case .model: "Model"
        case .skills: "Skills"
        case .activity: "Activity"
        case .previousChat: "Previous Chat"
        case .nextChat: "Next Chat"
        case .backToChat: "Back to Main Chat"
        case .agentSettings: "Agent Settings…"
        case .openComputer: "Open Computer Window"
        case .stopResponse: "Stop Response"
        case .keyboardShortcuts: "Keyboard Shortcuts…"
        }
    }
    var icon: String {
        switch self {
        case .settings, .agentSettings: "gearshape"
        case .newAgent: "plus"
        case .newGroup, .members: "person.3"
        case .importTemplate: "square.and.arrow.down"
        case .quickSwitcher: "magnifyingglass"
        case .toggleSidebar: "sidebar.left"
        case .toggleInfo, .overview: "info.circle"
        case .hiddenChats: "eye.slash"
        case .routines: "clock"
        case .media: "photo.on.rectangle"
        case .model: AgentInfoTab.model.symbol
        case .skills: AgentInfoTab.skills.symbol
        case .activity: AgentInfoTab.activity.symbol
        case .computer, .openComputer: "desktopcomputer"
        case .previousChat: "arrow.up"
        case .nextChat: "arrow.down"
        case .backToChat: "arrow.left"
        case .stopResponse: "stop.circle"
        case .keyboardShortcuts: "keyboard"
        }
    }
    var section: String {
        switch self {
        case .settings, .keyboardShortcuts: "App"
        case .newAgent, .newGroup, .importTemplate: "File"
        case .toggleSidebar, .toggleInfo, .hiddenChats, .overview, .routines, .media, .computer, .members, .model, .skills, .activity: "View"
        case .quickSwitcher, .previousChat, .nextChat, .backToChat: "Navigate"
        case .agentSettings, .openComputer, .stopResponse: "Chat"
        }
    }
    var key: KeyEquivalent {
        switch self {
        case .settings, .agentSettings: ","
        case .newAgent, .newGroup: "n"
        case .importTemplate: "o"
        case .quickSwitcher: "k"
        case .toggleSidebar: "s"
        case .toggleInfo: "i"
        case .hiddenChats: "h"
        case .overview: "1"
        case .routines: "2"
        case .media: "3"
        case .computer: "4"
        case .members: "5"
        case .model: "6"
        case .skills: "7"
        case .activity: "8"
        case .previousChat: .upArrow
        case .nextChat: .downArrow
        case .backToChat: "["
        case .openComputer: "c"
        case .stopResponse: "."
        case .keyboardShortcuts: "/"
        }
    }
    var modifiers: EventModifiers {
        switch self {
        case .newGroup, .importTemplate, .toggleInfo, .hiddenChats: [.command, .shift]
        case .toggleSidebar: [.command, .control]
        case .previousChat, .nextChat, .agentSettings, .openComputer: [.command, .option]
        default: .command
        }
    }
    var shortcutText: String {
        let symbol: String
        switch self {
        case .previousChat: symbol = "↑"
        case .nextChat: symbol = "↓"
        default: symbol = String(key.character).uppercased()
        }
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + "⌘" + symbol
    }
    var infoTab: AgentInfoTab? {
        switch self {
        case .overview: .overview
        case .routines: .routines
        case .media: .media
        case .computer: .computer
        case .members: .overview
        case .model: .model
        case .skills: .skills
        case .activity: .activity
        default: nil
        }
    }

    @MainActor func isEnabled(in store: AppStore) -> Bool {
        if self == .settings || self == .keyboardShortcuts { return true }
        guard !store.showingNewBot, !store.showingNewGroup, !store.showingTemplateImport, !store.showingGrokImport,
              store.editingBot == nil, store.errorMessage == nil else { return false }
        switch self {
        case .agentSettings: return store.selectedGroup == nil && store.selectedBot != nil
        case .overview, .routines, .media, .computer, .model, .skills, .activity:
            // P33: a tab an OpenClaw agent hides (nothing to show) is not offered.
            guard store.selectedGroup == nil, let bot = store.selectedBot, let tab = infoTab else { return false }
            return store.infoTabs(for: bot).contains(tab)
        case .members, .toggleInfo: return store.selectedGroup != nil || store.selectedBot != nil
        case .openComputer:
            return store.selectedGroup == nil && store.selectedBot.map { ComputerURL.validURL($0.computerURL) != nil } == true
        case .stopResponse: return store.openConversation.map(store.isStreaming(in:)) == true
        case .previousChat, .nextChat: return store.visibleChatCount > 1
        case .backToChat: return store.selectedGroup == nil && store.openThreadID != nil
        default: return true
        }
    }

    @MainActor func perform(in store: AppStore, openSettings: OpenSettingsAction, openWindow: OpenWindowAction) {
        guard isEnabled(in: store) else { return }
        switch self {
        case .settings: openSettings()
        case .keyboardShortcuts: openWindow(id: KeyboardShortcutsView.windowID)
        case .openComputer:
            if let bot = store.selectedBot { openWindow(id: ComputerWindow.id, value: bot.id) }
        default:
            // Workspace commands stay useful from Settings and the Computer window too.
            if let window = NSApp.windows.first(where: { $0.title == AppConstants.name }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: ContentView.windowID)
            }
            performWorkspaceAction(in: store)
        }
    }

    @MainActor func performWorkspaceAction(in store: AppStore) {
        guard isEnabled(in: store) else { return }
        if let infoTab {
            store.infoTab = infoTab
            store.showInfo = true
            return
        }
        switch self {
        case .newAgent: store.showingNewBot = true
        case .newGroup: store.showingNewGroup = true
        case .importTemplate: store.showingTemplateImport = true
        case .quickSwitcher: store.showingCommandPalette = true
        case .toggleSidebar: store.sidebarHidden.toggle()
        case .toggleInfo: store.showInfo.toggle()
        case .hiddenChats: store.sidebarHidden = false; store.showingHiddenBots.toggle()
        case .previousChat: store.moveChatSelection(by: -1)
        case .nextChat: store.moveChatSelection(by: 1)
        case .backToChat: store.closeThread()
        case .agentSettings: store.editingBot = store.selectedBot
        case .stopResponse: store.stop()
        default: break
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var updater: AppUpdater
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The Settings scene supplies the native Settings… item and ⌘, binding.
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updater.checkForUpdates).disabled(!updater.canCheckForUpdates)
        }
        // Replace the default New Window binding so ⌘N creates exactly one agent.
        CommandGroup(replacing: .newItem) {
            command(.newAgent)
            command(.newGroup)
            Divider()
            command(.importTemplate)
        }
        CommandGroup(replacing: .sidebar) {
            command(.toggleSidebar)
            command(.toggleInfo)
            command(.hiddenChats)
            Menu("Agent Details") {
                command(.overview)
                command(.model)
                command(.skills)
                command(.activity)
                command(.routines)
                command(.media)
                command(.computer)
                command(.members)
            }
        }
        CommandMenu("Navigate") {
            command(.quickSwitcher)
            Divider()
            command(.previousChat)
            command(.nextChat)
            command(.backToChat)
        }
        CommandMenu("Chat") {
            command(.agentSettings)
            command(.openComputer)
            Divider()
            command(.stopResponse)
        }
        CommandGroup(replacing: .help) {
            command(.keyboardShortcuts)
            // P36: Konrad's own report, prefilled without keys; nothing is sent until Send.
            Button("Report a Problem…") { store.startUserReport(); openWindow(id: ContentView.windowID) }
        }
    }

    private func command(_ command: AppCommand) -> some View {
        Button(command.title) { command.perform(in: store, openSettings: openSettings, openWindow: openWindow) }
            .keyboardShortcut(command.key, modifiers: command.modifiers)
            .disabled(!command.isEnabled(in: store) || (command != .keyboardShortcuts && store.showingCommandPalette))
    }
}

struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"
    var body: some View {
        Form {
            ForEach(["App", "File", "View", "Navigate", "Chat"], id: \.self) { section in
                Section(section) {
                    ForEach(AppCommand.allCases.filter { $0.section == section }) { command in
                        LabeledContent(command.title.replacingOccurrences(of: "…", with: "")) {
                            Text(command.shortcutText).monospaced().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Writing messages") {
                LabeledContent("Send message", value: "Return")
                LabeledContent("Insert a new line", value: "⇧Return")
            }
        }.formStyle(.grouped).frame(width: 460, height: 650)
    }
}
