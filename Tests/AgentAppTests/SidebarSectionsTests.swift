import Foundation
import Testing
@testable import AgentApp

// Sidebar sections and pins: the model and its layout first, then the saved file, then the store.

@Suite @MainActor struct SidebarSectionsTests {
    private func message(_ time: TimeInterval) -> ChatMessage {
        ChatMessage(role: .user, content: "Hello", createdAt: Date(timeIntervalSince1970: time))
    }

    /// Newest first: a (300), g (200), b (100), c (no messages).
    private func fixture() -> (bots: [Bot], group: GroupChat, chats: [SidebarChat]) {
        let a = Bot(name: "A", messages: [message(300)]), b = Bot(name: "B", messages: [message(100)]), c = Bot(name: "C")
        let g = GroupChat(name: "Crew", memberIDs: [], messages: [message(200)])
        return ([a, b, c], g, [.bot(a), .group(g), .bot(b), .bot(c)])
    }

    private func ids(_ chats: [SidebarChat]) -> [UUID] { chats.map(\.id) }

    @Test func aMoveIsExclusive() {
        var org = SidebarOrganisation(); let chat = UUID()
        let one = org.createSection(named: "One"), two = org.createSection(named: "Two")
        org.moveChat(chat, toSection: one); org.moveChat(chat, toSection: two)
        #expect(org.sections[0].chats.isEmpty && org.sections[1].chats == [chat])
        org.moveChat(chat, toSection: nil)
        #expect(org.sectionID(of: chat) == nil)
    }

    @Test func deletingASectionReturnsItsChatsToUnsectioned() {
        let f = fixture()
        var org = SidebarOrganisation()
        let section = org.createSection(named: "Work", adding: f.bots[0].id)
        org.deleteSection(section!)
        let layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(layout.sections.count == 1 && ids(layout.sections[0].chats) == ids(f.chats))
    }

    @Test func nameRules() {
        var org = SidebarOrganisation()
        #expect(org.validatedName("   ") == nil)
        #expect(org.validatedName(String(repeating: "x", count: 49)) == nil)
        #expect(org.validatedName(String(repeating: "x", count: 48)) != nil)
        #expect(org.validatedName("  Work  ") == "Work")
        #expect(org.validatedName("pinned") == nil && org.validatedName("UNSECTIONED") == nil)
        org.createSection(named: "Work")
        #expect(org.validatedName("work") == nil)
        let duplicate = org.createSection(named: "WORK")
        #expect(duplicate == nil && org.sections.count == 1)
        let id = org.sections[0].id
        let renamed = org.renameSection(id, to: "WORK")
        #expect(renamed && org.sections[0].name == "WORK")
    }

    @Test func pinsKeepOrderUnpinAndCap() {
        var org = SidebarOrganisation()
        let all = (0..<10).map { _ in UUID() }
        for id in all.prefix(9) {
            let pinned = org.pin(id)
            #expect(pinned)
        }
        let overCap = org.pin(all[9])
        #expect(!org.canPinMore && !overCap && org.pinned == Array(all.prefix(9)))
        org.unpin(all[0])
        #expect(org.canPinMore)
        let afterUnpin = org.pin(all[9])
        #expect(afterUnpin && org.pinned.last == all[9] && org.pinned.count == 9)
    }

    @Test func pruneDropsUnknownAndDuplicateIds() {
        var org = SidebarOrganisation(); let keep = UUID(), gone = UUID()
        org.pinned = [keep, gone, keep]
        let one = org.createSection(named: "One"), two = org.createSection(named: "Two")
        org.sections[0].chats = [keep, gone]; org.sections[1].chats = [keep]
        _ = (one, two)
        org.prune(keeping: [keep])
        #expect(org.pinned == [keep] && org.sections[0].chats == [keep] && org.sections[1].chats.isEmpty)
    }

    @Test func noOrganisationIsOneHeaderlessBucketEqualToTheInput() {
        let f = fixture()
        let layout = SidebarLayout.make(chats: f.chats, organisation: SidebarOrganisation())
        #expect(layout.pinned.isEmpty && layout.sections.count == 1)
        #expect(!layout.sections[0].showsHeader && !layout.sections[0].isCollapsed)
        #expect(ids(layout.sections[0].chats) == ids(f.chats) && ids(layout.navigationOrder) == ids(f.chats))
    }

    @Test func sectionOrderThenRecencyInside() {
        let f = fixture()
        var org = SidebarOrganisation()
        let late = org.createSection(named: "Late"), early = org.createSection(named: "Early")
        org.moveSection(early!, by: -1)
        org.moveChat(f.bots[1].id, toSection: late); org.moveChat(f.bots[0].id, toSection: late)
        org.moveChat(f.group.id, toSection: early)
        let layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(layout.sections.map(\.name) == ["Early", "Late", "Unsectioned"])
        #expect(ids(layout.sections[1].chats) == [f.bots[0].id, f.bots[1].id], "newest first inside a section")
        #expect(layout.sections[2].showsHeader && ids(layout.sections[2].chats) == [f.bots[2].id])
        #expect(ids(layout.navigationOrder) == [f.group.id, f.bots[0].id, f.bots[1].id, f.bots[2].id])
    }

    @Test func pinnedLeaveTheSectionsAndComeBackOnUnpin() {
        let f = fixture()
        var org = SidebarOrganisation()
        let section = org.createSection(named: "Work", adding: f.bots[0].id)
        _ = org.pin(f.bots[0].id); _ = org.pin(f.group.id)
        var layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(ids(layout.pinned) == [f.bots[0].id, f.group.id], "groups pin too, in pin order")
        #expect(layout.sections[0].id == section && layout.sections[0].chats.isEmpty)
        #expect(ids(layout.navigationOrder).prefix(2) == [f.bots[0].id, f.group.id][...])
        org.unpin(f.bots[0].id)
        layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(ids(layout.sections[0].chats) == [f.bots[0].id], "membership was kept")
    }

    @Test func aPinWithNoSectionsShowsNoHeaders() {
        let f = fixture()
        var org = SidebarOrganisation(); org.pin(f.bots[1].id)
        let layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(!layout.sections[0].showsHeader && layout.sections[0].chats.count == 3)
    }

    @Test func droppingPinnedChatsMovesBotsAndGroupsInTheSavedOrder() throws {
        let url = temporaryStore()
        let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let f = fixture()
        store.bots = f.bots
        store.groups = [f.group]
        let pins = ids(f.chats)
        for pin in pins { store.setPinned(pin, true) }
        #expect(store.movePinnedChat(f.group.id, onto: pins[3]))
        #expect(ids(store.sidebarLayout.pinned) == [pins[0], pins[2], pins[3], f.group.id])
        #expect(store.movePinnedChat(pins[3], onto: pins[0]))
        #expect(!store.movePinnedChat(UUID(), onto: pins[0]))
        #expect(!store.movePinnedChat(pins[0], onto: UUID()))
        let expected = [pins[3], pins[0], pins[2], f.group.id]
        #expect(ids(store.sidebarLayout.navigationOrder) == expected)
        let saved = try StoreFile.decode(Data(contentsOf: url))
        #expect(saved.sidebar?.pinned == expected)
    }

    @Test func foldedRowsAreOutOfNavigationButCounted() {
        let f = fixture()
        var org = SidebarOrganisation()
        let section = org.createSection(named: "Work", adding: f.bots[0].id)
        org.moveChat(f.group.id, toSection: section)
        org.setCollapsed(section, true)
        let layout = SidebarLayout.make(chats: f.chats, organisation: org)
        #expect(layout.sections[0].isCollapsed && layout.sections[0].chats.count == 2)
        #expect(ids(layout.navigationOrder) == [f.bots[1].id, f.bots[2].id])
        org.setCollapsed(nil, true)
        #expect(SidebarLayout.make(chats: f.chats, organisation: org).navigationOrder.isEmpty)
    }

    @Test func anUntouchedStoreEncodesWithNoSidebarKey() throws {
        let data = try JSONEncoder().encode(StoreFile(bots: [], groups: []))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["sidebar"] == nil)
        #expect(StoreFile.currentVersion == 2)
    }

    @Test func sectionsFoldsAndPinsSurviveAStoreFileRoundTrip() throws {
        let f = fixture()
        var org = SidebarOrganisation()
        let section = org.createSection(named: "Work", adding: f.bots[0].id)
        org.setCollapsed(section, true); org.setCollapsed(nil, true); org.pin(f.group.id)
        var file = StoreFile(bots: f.bots, groups: [f.group]); file.sidebar = org
        let back = try StoreFile.decode(JSONEncoder().encode(file))
        #expect(back.sidebar == org && back.bots.count == 3)
    }

    @Test func aMalformedSidebarValueStillDecodesTheRestOfTheStore() throws {
        let f = fixture()
        let data = try JSONEncoder().encode(StoreFile(bots: f.bots, groups: [f.group]))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["sidebar"] = ["pinned": "not a list", "sections": 7]
        let back = try StoreFile.decode(JSONSerialization.data(withJSONObject: json))
        #expect(back.bots.count == 3 && back.groups.count == 1 && back.sidebar == nil)
    }

    @Test func theStoreNavigatesTheLayoutAndSavesIt() throws {
        let url = temporaryStore()
        let store = AppStore(storeURL: url, autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        store.bots = []; store.groups = []; store.selectedBot = nil
        let f = fixture()
        store.bots = f.bots; store.groups = [f.group]
        #expect(store.sidebarLayout.navigationOrder.map(\.id) == store.sidebarChats.map(\.id), "untouched: identical")
        store.setPinned(f.bots[2].id, true)
        store.open(f.bots[2]); store.moveChatSelection(by: 1)
        #expect(store.selectedBot === f.bots[0], "pinned first, then the list")
        store.save()
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["sidebar"] != nil)
        store.setPinned(f.bots[2].id, false); store.save()
        let cleared = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(cleared["sidebar"] == nil)
    }
}
