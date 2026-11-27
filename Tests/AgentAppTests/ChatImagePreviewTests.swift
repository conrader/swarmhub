import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@MainActor @Test(arguments: [false, true])
func sentImagePreviewKeepsBothEnds(portrait: Bool) async throws {
    let size = portrait ? CGSize(width: 100, height: 400) : CGSize(width: 400, height: 100)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.green.setFill()
        rect.fill()
        NSColor.red.setFill()
        let band = portrait ? CGRect(x: 0, y: 0, width: 100, height: 50) : CGRect(x: 0, y: 0, width: 50, height: 100)
        band.fill()
        NSColor.blue.setFill()
        band.offsetBy(dx: portrait ? 0 : 350, dy: portrait ? 350 : 0).fill()
        return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let bytes = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    let store = AppStore(storeURL: temporaryStore(), autoStart: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let attachment = try #require(store.prepareAttachment(imageData: bytes, name: "screen.png"))
    let view = AttachmentThumbnails(attachments: [attachment]).environmentObject(store)
    let rendered = try #require(await SnapshotRenderer.png(view, size: CGSize(width: 210, height: 265), scale: 1))
    let pixels = try #require(NSBitmapImageRep(data: rendered))
    var red = 0, blue = 0
    for y in stride(from: 0, to: pixels.pixelsHigh, by: 3) {
        for x in stride(from: 0, to: pixels.pixelsWide, by: 3) {
            guard let color = pixels.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 { red += 1 }
            if color.blueComponent > 0.8 && color.greenComponent < 0.2 && color.redComponent < 0.2 { blue += 1 }
        }
    }
    #expect(red > 20 && blue > 20, "Both colored edges must be visible in the transcript.")
}
