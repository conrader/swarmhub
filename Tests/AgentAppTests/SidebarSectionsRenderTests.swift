import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor @Test(arguments: [240, 280, 320])
func pinnedRowsCenterTheirOccupiedTiles(sidebarWidth: Int) throws {
    let inset = SidebarMetrics.listInset
    let width = CGFloat(sidebarWidth) - 2 * inset
    let tileWidth = (width - 8) / 3
    for count in 0...SidebarOrganisation.maxPinned {
        let tiles = SidebarPinnedStrip.layout.frames(in: width, count: count) { _, proposedWidth in
            #expect(abs(proposedWidth - tileWidth) < 0.001)
            return 100
        }
        #expect(tiles.count == count)
        for start in stride(from: 0, to: tiles.count, by: 3) {
            let row = tiles[start..<min(start + 3, count)]
            let first = try #require(row.first), last = try #require(row.last)
            #expect(abs(inset + (first.minX + last.maxX) / 2 - CGFloat(sidebarWidth) / 2) < 0.001)
            for tile in row {
                #expect(abs(tile.width - tileWidth) < 0.001 && tile.height == 100)
                #expect(tile.minY == CGFloat(start / 3) * 104)
                #expect(tile.minX >= -0.001 && tile.maxX <= width + 0.001)
            }
            for (left, right) in zip(row, row.dropFirst()) {
                #expect(abs(right.minX - left.maxX - 4) < 0.001)
            }
        }
    }
}

/// Keep both buttons mounted across the transfer. The only magenta ink in this fixture is the role star.
@MainActor @Test func mainBotStarMovesFromPinnedAvatarToRegularBotName() async throws {
    _ = NSApplication.shared
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let pinned = Bot(name: "Pinned", backend: .herdr, avatarName: .faceMint)
    let regular = Bot(name: "Regular", backend: .herdr, avatarName: .faceMint)
    let group = GroupChat(name: "Group", memberIDs: [pinned.id, regular.id])
    store.bots = [pinned, regular]
    store.groups = [group]
    store.selectedBot = nil
    store.selectedGroup = nil
    let size = CGSize(width: 300, height: 200)
    let view = VStack(spacing: 0) {
        SidebarPinnedStrip(chats: [.bot(pinned), .group(group)], askNewSection: { _ in }, requestDelete: { _ in })
        BotRow(bot: regular, drafts: store.drafts, selected: false, botToDelete: .constant(nil))
    }
    .frame(width: size.width, height: size.height, alignment: .top)
    .environmentObject(store).tint(Color(nsColor: .magenta)).background(Color.white)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    func starColumns() async throws -> IndexSet {
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let scale = CGFloat(image.pixelsWide) / size.width
        var columns = IndexSet()
        for x in 0..<image.pixelsWide {
            for y in 0..<image.pixelsHigh {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // The display profile can raise green when converting the tinted glyph to sRGB.
                let magenta = min(color.redComponent, color.blueComponent)
                if magenta > 0.8 && magenta - color.greenComponent > 0.5 {
                    columns.insert(Int(CGFloat(x) / scale))
                    break
                }
            }
        }
        return columns
    }

    store.setCanManageBots(pinned, true)
    let first = try await starColumns()
    // The pinned mark starts at x=71; its group neighbour starts at x=173.
    #expect(first.count >= 6 && first.allSatisfy { (70...92).contains($0) })
    store.setCanManageBots(regular, true)
    let next = try await starColumns()
    let nameWidth = (regular.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: SidebarMetrics.nameSize, weight: .medium)]).width
    let nameEnd = Int(SidebarMetrics.rowPadding + SidebarMetrics.mark + SidebarMetrics.markGap + nameWidth)
    #expect(next.count >= 5 && next.allSatisfy { (nameEnd...(nameEnd + 20)).contains($0) })
    store.setCanManageBots(regular, false)
    let cleared = try await starColumns()
    #expect(cleared.isEmpty)
}

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
        let view = ReviewUpdatesButton(notice: notice)
            .frame(width: SidebarMetrics.width.min).background(AppColor.sidebar)
            .tint(AppTheme.accentColor(for: AppTheme.defaultAccent))
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        #expect(size.width == SidebarMetrics.width.min && size.height >= 44 && size.height < 90)
        let data = try #require(await SnapshotRenderer.png(view, size: size, scheme: scheme))
        try data.write(to: folder.appending(path: "update-\(scheme == .dark ? "dark" : "light").png"))
    }
}

@MainActor @Test func compactUpdateNoticeFitsTheHeaderAndDisappearsWhenCurrent() {
    let notice = UpdateNotice()
    let button = ReviewUpdatesButton(compact: true, notice: notice)
    #expect(NSHostingView(rootView: button).fittingSize == .zero)

    notice.appVersion = "0.8.16"
    let size = NSHostingView(rootView: button).fittingSize
    #expect(size.width > 24 && size.width < 110)
    #expect(size.height == 24)
}
