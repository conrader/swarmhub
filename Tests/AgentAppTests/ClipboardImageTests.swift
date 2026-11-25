import AppKit
import Testing
import UniformTypeIdentifiers
@testable import AgentApp

@MainActor struct ClipboardImageTests {
    @Test func imagesWinOverTheirTextAlternativesInClipboardOrder() throws {
        let formats = [UTType.png, .jpeg, .gif, .webP]
        let items = formats.enumerated().map { index, format in
            let item = NSPasteboardItem()
            item.setString("Clipboard label", forType: .string)
            item.setData(Data([UInt8(index)]), forType: .init(format.identifier))
            return item
        }
        guard case .images(let images) = PasteboardAttachments.item(files: [], items: items) else {
            Issue.record("Expected four image attachments")
            return
        }
        #expect(images.map(\.data) == [Data([0]), Data([1]), Data([2]), Data([3])])
        let names = try formats.map { type in
            let ext = try #require(type.preferredFilenameExtension)
            return "Pasted image." + ext
        }
        #expect(images.map(\.name) == names)
    }

    @Test func finderFileWinsOverThumbnailAndTextPastesNormally() {
        let item = NSPasteboardItem()
        item.setString("Message text", forType: .string)
        #expect(PasteboardAttachments.item(files: [], items: [item]) == nil)
        item.setData(Data([1]), forType: .png)
        let file = URL(fileURLWithPath: "/tmp/QA-clip.mp4")
        guard case .files(let urls) = PasteboardAttachments.item(files: [file], items: [item]) else {
            Issue.record("Expected the original file")
            return
        }
        #expect(urls == [file])
    }
}
