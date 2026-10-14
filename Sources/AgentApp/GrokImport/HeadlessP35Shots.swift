import AppKit
import SwiftUI

/// P35 shots of `--render-setup`: the setup window's "Found 23 bots on this box" step with the bots SwarmHub will
/// connect (as shown, and the whole list in a taller frame), the confirmation sheet, the sidebar's "On this box · not
/// connected" section and an adopted bot's "Restore this bot's old key". Throwaway in-memory stores, a mock backend;
/// the scan is built in memory: no network, no Keychain.
@MainActor enum HeadlessP35Shots {
    static let names = ["p35-s4-found-bots", "p35-s4-found-bots-full", "p35-adoption-sheet", "p35-sidebar-not-connected", "p35-editor-restore-key"]
    static let adopted = ["cfo", "krytyk", "sekretarz", "wingman", "knowledge-guide", "lowcost"]
    static let grok = ["grok-jarvis", "grok-rapper", "grok-chef", "grok-coach", "grok-doctor", "grok-lawyer", "grok-tutor", "grok-poet",
                       "grok-trainer", "grok-planner", "grok-critic", "grok-scout", "grok-banker", "grok-gardener", "grok-mechanic", "grok-pilot"]

    static func render(write: (String, Data?) -> Void, png: @MainActor (AnyView, AppStore, NSSize) async -> Data?) async {
        // Konrad's box (2026-10-14): Ermes (default, its key typed here), the 16 Grok bots already in SwarmHub, 6 made before.
        let store = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); store.isSetupPreview = false
        store.bots = grok.map { Bot(name: HermesProfileNaming.botName(forProfile: $0), backend: .hermes, hermesProfile: $0) }
        let box = BoxAddress.url("my-box.example.com")!
        var flow = SetupFlow(prefill: .init(startAtAddress: true)); flow.input = .init(address: "my-box.example.com", key: "synthetic")
        let ermes = HermesProfileProbe(id: "default", status: .available(.init(id: "default", name: "Ermes", model: "hermes-agent")))
        flow.apply(.test(SetupCheckResult(outcome: .connected(place: box.host ?? "", count: 1), baseURL: box, probes: [ermes])))
        flow.preselect(alreadyAdded: store.addedProfileIDs)
        flow.apply(.boxScanned(SetupBoxScan(managerName: "Ermes", managerProfile: "default", managerIsNew: true, listed: 1 + grok.count + adopted.count,
                                            adoptable: adopted)))
        write(names[0], await png(AnyView(SetupView(preset: flow)), store, HeadlessSetup.size))
        // The window scrolls; the step alone in a taller frame shows the whole list.
        let step = SetupChooseStep(flow: .constant(flow), added: store.addedProfileIDs).padding(24).frame(width: HeadlessSetup.size.width, height: 900, alignment: .top)
        write(names[1], await png(AnyView(step.background(AppColor.panel)), store, NSSize(width: HeadlessSetup.size.width, height: 900)))

        let manager = Bot(name: "Jarvis", backend: .hermes, hermesProfile: "grok-jarvis"); manager.canManageBots = true
        store.bots[0] = manager
        let offer = AdoptionOffer(managerID: manager.id, managerName: manager.name, names: adopted)
        write(names[2], await png(AnyView(AdoptionSheet(offer: offer, close: {}).background(AppColor.panel)), store, NSSize(width: 460, height: 470)))

        let sidebar = SetupPreview.makeStore(backendFactory: { _ in MockBackend() }); sidebar.isSetupPreview = false
        let jarvis = Bot(name: "Jarvis", backend: .hermes, messages: [ChatMessage(role: .assistant, content: "Connected Cfo, Krytyk.")], hermesProfile: "grok-jarvis")
        jarvis.canManageBots = true
        let cfo = Bot(name: "Cfo", backend: .hermes, hermesProfile: "cfo"); cfo.adoptedKeyBackup = ".env.swarmhub-bak-20261015T101500Z"
        sidebar.bots = [jarvis, Bot(name: "Rapper", backend: .hermes, hermesProfile: "grok-rapper"), cfo, Bot(name: "Krytyk", backend: .hermes, hermesProfile: "krytyk")]
        sidebar.selectedBot = jarvis
        sidebar.boxProfiles[sidebar.connection(of: jarvis)] = [BoxProfile(name: "default", hasKey: true, state: .needsKey),
                                                               BoxProfile(name: "sekretarz", hasKey: true, state: .adopting),
                                                               BoxProfile(name: "wingman", hasKey: true, state: .failed),
                                                               BoxProfile(name: "lowcost", hasKey: false, state: .adoptable)]
        let column = SidebarView(selection: .constant(jarvis)).frame(width: SidebarMetrics.width.ideal, height: 640)
        write(names[3], await png(AnyView(column), sidebar, NSSize(width: SidebarMetrics.width.ideal, height: 640)))
        let restore = Form { RestoreOldKeySection(bot: cfo) }.formStyle(.grouped).frame(width: 560, height: 220).background(AppColor.panel)
        write(names[4], await png(AnyView(restore), sidebar, NSSize(width: 560, height: 220)))
    }
}
