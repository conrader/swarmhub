import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor @Test func outgoingBubblesFitShortTextAndWrapAtTheChatEdge() async throws {
    let defaults = isolatedDefaults()
    defaults.set("Blue", forKey: "accent")
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: defaults)
    func bubble(_ text: String, width: Int) async throws -> CGRect {
        let message = ChatMessage(role: .user, content: text)
        let selection = MessageSelection()
        let row = MessageView(message: message, reply: {})
            .selectableMessage(message.id, in: selection).messageSelectionContent(selection)
            .environmentObject(store).defaultAppStorage(defaults)
        let data = try #require(await SnapshotRenderer.png(row, size: .init(width: width, height: 280), scale: 1, scheme: .dark))
        let image = try #require(NSBitmapImageRep(data: data))
        var fill = CGRect.null
        for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                guard let c = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.98, c.blueComponent > c.redComponent + 0.07,
                      c.blueComponent < 0.40 else { continue }
                fill = fill.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        try #require(!fill.isNull)
        return fill
    }
    let compact = try await bubble("Dziękuję", width: 420)
    let wide = try await bubble("Dziękuję", width: 700)
    let multiline = try await bubble(String(repeating: "Sprawdź teraz te zmiany. ", count: 6), width: 420)
    #expect(compact.width < 110 && abs(compact.width - wide.width) <= 2)
    #expect(abs((wide.maxX - compact.maxX) - 280) <= 2)
    #expect(multiline.width > compact.width && multiline.height > compact.height * 2)
    #expect(abs(multiline.maxX - compact.maxX) <= 2)
}
