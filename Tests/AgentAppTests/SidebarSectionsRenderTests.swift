import AppKit
import SwiftUI
import Testing
@testable import AgentApp

/// The sidebar with nothing organised, then with pins, two sections and a fold, rendered offscreen for review and
/// written to `$TMPDIR/AgentAppSnapshots-sidebar/`. Synthetic bots only.
@MainActor @Test func theOrganisedSidebarRenders() async throws {
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    func message(_ time: TimeInterval, _ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text, createdAt: Date(timeIntervalSince1970: time))
    }
    let names = ["Jarvis", "Reactor", "Infra", "Plainsay", "Builder", "Boppy", "Finance Controller", "A bot with a very long name indeed"]
    var bots: [Bot] = []
    for (index, name) in names.enumerated() {
        bots.append(Bot(name: name, messages: [message(Double(1000 - index * 10), "Latest line from \(name)")]))
    }
    let crew = GroupChat(name: "Crew", memberIDs: [bots[0].id, bots[1].id], messages: [message(500, "A line in the group")])
    store.bots = bots
    store.groups = [crew]
    store.selectedBot = bots[4]

    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppSnapshots-sidebar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func render(_ name: String) async throws {
        let view = SidebarView(selection: .constant(store.selectedBot)).environmentObject(store)
            .defaultAppStorage(store.defaults).frame(width: 300, height: 760).background(AppColor.sidebar)
        let data = try #require(await SnapshotRenderer.png(view, size: NSSize(width: 300, height: 760), scale: 2))
        let image = try #require(NSBitmapImageRep(data: data))
        #expect(image.pixelsWide == 600 && image.pixelsHigh == 1520, "\(name)")
        try data.write(to: folder.appending(path: "\(name).png"))
    }
    try await render("0-plain")

    store.createSidebarSection(named: "Work", adding: bots[1].id)
    store.createSidebarSection(named: "Side projects", adding: bots[5].id)
    let work = try #require(store.sidebar.sections.first { $0.name == "Work" })
    let side = try #require(store.sidebar.sections.first { $0.name == "Side projects" })
    store.moveChat(bots[2].id, toSection: work.id)
    store.moveChat(bots[3].id, toSection: work.id)
    store.moveChat(bots[6].id, toSection: side.id)
    store.setPinned(bots[0].id, true)
    store.setPinned(bots[4].id, true)
    store.setPinned(crew.id, true)
    store.setPinned(bots[7].id, true)
    let layout = store.sidebarLayout
    // Every chat is pinned or in a section, so no empty "Unsectioned" is listed.
    #expect(layout.pinned.count == 4 && layout.sections.map(\.name) == ["Work", "Side projects"])
    try await render("1-sections-and-pins")

    store.setSidebarSectionCollapsed(side.id, true)
    #expect(store.sidebarLayout.sections.first { $0.id == side.id }?.isCollapsed == true)
    try await render("2-one-section-folded")
}

@MainActor @Test func updateNoticeFitsTheNarrowSidebarInBothAppearances() async throws {
    let notice = UpdateNotice()
    notice.appVersion = "0.8.10"
    notice.serversBehind = 2
    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppSnapshots-sidebar", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
        let view = SidebarUpdateButton(notice: notice)
            .frame(width: SidebarMetrics.width.min).background(AppColor.sidebar)
            .tint(AppTheme.accentColor(for: AppTheme.defaultAccent))
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        #expect(size.width == SidebarMetrics.width.min && size.height >= 44 && size.height < 90)
        let data = try #require(await SnapshotRenderer.png(view, size: size, scheme: scheme))
        try data.write(to: folder.appending(path: "update-\(scheme == .dark ? "dark" : "light").png"))
    }
}
