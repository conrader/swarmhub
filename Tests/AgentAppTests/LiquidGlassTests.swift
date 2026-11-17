import AppKit
import SwiftUI
import Testing
@testable import AgentApp

/// Liquid Glass: decided in one place, drawn for the layer of controls and never for content. The material cannot
/// be photographed offscreen (a view with glass in it draws blank), so these tests look at what a window is built
/// from instead: on macOS 26 a glass surface puts a backdrop layer into the view's layers, and a plain one does not.
@MainActor struct LiquidGlassTests {
    /// The layers of `view`, laid out in a window that is never shown, that belong to a glass surface.
    private func glassLayers<V: View>(in view: V, allowed: Bool, size: NSSize = NSSize(width: 640, height: 240)) async throws -> Int {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.environment(\.glassAllowed, allowed).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
        func layers(_ layer: CALayer) -> [CALayer] { [layer] + (layer.sublayers ?? []).flatMap(layers) }
        return (host.layer.map(layers) ?? []).filter { String(describing: type(of: $0)).contains("Backdrop") }.count
    }

    private func makeStore() -> AppStore {
        AppStore(storeURL: temporaryStore(), autoStart: false, backendFactory: { _ in TestBackend() }, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    @Test func oneFunctionDecidesWhetherGlassIsDrawn() {
        let on = AppGlass.isOn(allowed: true, reduceTransparency: false, contrast: .standard)
        if #available(macOS 26.0, *) { #expect(on, "this Mac has the material") } else { #expect(!on, "before macOS 26 there is none") }
        #expect(!AppGlass.isOn(allowed: false, reduceTransparency: false, contrast: .standard))
        #expect(!AppGlass.isOn(allowed: true, reduceTransparency: true, contrast: .standard), "Reduce Transparency draws the plain surface")
        #expect(!AppGlass.isOn(allowed: true, reduceTransparency: false, contrast: .increased), "Increase Contrast draws the plain surface")
        #expect(!AppGlass.byDefault, "a test run, like a render, draws the plain surfaces: they are what can be put into a picture")
    }

    @Test func theMessageBoxIsGlassWhereTheMacHasIt() async throws {
        let composer = ComposerView(text: .constant(""), attachments: .constant([]), isStreaming: false, send: {}, stop: {}).background(AppColor.chat)
        #expect(try await glassLayers(in: composer, allowed: false) == 0, "the surface of before has no backdrop layer")
        let found = try await glassLayers(in: composer, allowed: true)
        if #available(macOS 26.0, *) { #expect(found > 0, "the message box is a glass surface") } else { #expect(found == 0) }
    }

    @Test func aCardAboveTheMessageBoxIsGlassAndAMessageInTheChatIsNot() async throws {
        let store = makeStore()
        let infra = Bot(name: "Infra", backend: .herdr), jarvis = Bot(name: "Jarvis", backend: .herdr)
        store.bots = [jarvis, infra]
        store.herdrPrompts[infra.id] = HerdrPrompt(program: "Agent One", question: "Run this?\n› Yes\n  No", agent: .init(address: "t7", createdMs: 1), since: .now)
        let card = HerdrPromptCard(bot: infra).environmentObject(store).background(AppColor.chat)
        let onCard = try await glassLayers(in: card, allowed: true)
        if #available(macOS 26.0, *) { #expect(onCard > 0, "what waits for the person floats above the chat") } else { #expect(onCard == 0) }
        // Content stays on plain surfaces, whatever the Mac: a message between bots, unfolded, and a reply.
        let message = ChatMessage(role: .user, content: HerdrBotRelay.message(from: jarvis.name, "Please set up the registry.\n\nThen tell me."),
                                  metadata: [HerdrBotRelay.Key.kind: HerdrBotRelay.message, HerdrBotRelay.Key.asker: jarvis.id.uuidString.lowercased(), HerdrBotRelay.Key.name: jarvis.name])
        let reply = ChatMessage(role: .assistant, content: "Done.\n\n```choices\nNext?\n- Stop\n- Go on\n```")
        let chat = VStack { MessageView(message: message); MessageView(message: reply, author: infra) }
            .environment(\.chatFolds, ChatFolds(open: [message.id])).environmentObject(store).background(AppColor.chat)
        #expect(try await glassLayers(in: chat, allowed: true, size: NSSize(width: 700, height: 500)) == 0, "the words of a chat and its cards are not glass")
    }

    @Test func aWholeChatAndTheSidebarLayOutWithTheirFloatingBars() async throws {
        // The floating bars (`safeAreaBar`, the soft scroll edge, the group of glass surfaces) are built and laid out
        // in the real views, with the material and without it.
        let store = makeStore()
        let infra = Bot(name: "Infra", backend: .herdr), jarvis = Bot(name: "Jarvis", backend: .herdr)
        jarvis.canManageBots = true
        store.bots = [jarvis, infra]; store.selectedBot = jarvis
        jarvis.messages = (0..<12).flatMap { index in [ChatMessage(role: .user, content: "Question \(index)"), ChatMessage(role: .assistant, content: "Answer \(index).\n\nWith a second paragraph.")] }
        store.herdrPrompts[jarvis.id] = HerdrPrompt(program: "Agent One", question: "Run this?", agent: .init(address: "t7", createdMs: 1), since: .now)
        let size = NSSize(width: 860, height: 600)
        let chat = ChatView(bot: jarvis).environmentObject(store).defaultAppStorage(store.defaults)
        let sidebar = SidebarView(selection: .constant(jarvis)).environmentObject(store).defaultAppStorage(store.defaults)
        #expect(try await glassLayers(in: chat, allowed: false, size: size) == 0)
        #expect(try await glassLayers(in: sidebar, allowed: false, size: NSSize(width: 280, height: 500)) == 0)
        let inChat = try await glassLayers(in: chat, allowed: true, size: size), inSidebar = try await glassLayers(in: sidebar, allowed: true, size: NSSize(width: 280, height: 500))
        if #available(macOS 26.0, *) {
            #expect(inChat > 0, "the message box and the card on it")
            #expect(inSidebar > 0, "the Settings button at the foot of the sidebar")
        } else { #expect(inChat == 0 && inSidebar == 0) }
    }
}
