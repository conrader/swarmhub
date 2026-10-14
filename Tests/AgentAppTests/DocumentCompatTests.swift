import AppKit
import Foundation
import Testing
@testable import AgentApp

/// P19: RTF/DOC/DOCX, cancellation, threading, stored-JSON compatibility and the Polish OCR model.
private func workspace() -> (folder: URL, encoder: AttachmentEncoder) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-compat-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return (folder, AttachmentEncoder(directory: folder.appending(path: "attachments")))
}

private final class PageLog: @unchecked Sendable {
    private let lock = NSLock(); private var pages: [Int] = []; private var main: [Bool] = []
    func add(_ page: Int, main isMain: Bool) { lock.lock(); pages.append(page); main.append(isMain); lock.unlock() }
    var seen: [Int] { lock.lock(); defer { lock.unlock() }; return pages }
    var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return main }
}

@Test func rtfDocAndDocxRoundTripAsPlainText() async throws {
    let (folder, encoder) = workspace()
    let source = NSAttributedString(string: "MARKER office text\nSecond line with Zażółć gęślą jaźń")
    for (ext, type, label) in [("rtf", NSAttributedString.DocumentType.rtf, "RTF"), ("doc", .docFormat, "DOC"), ("docx", .officeOpenXML, "DOCX")] {
        let data = try source.data(from: NSRange(location: 0, length: source.length), documentAttributes: [.documentType: type])
        let url = folder.appending(path: "letter.\(ext)"); try data.write(to: url)
        let item = try #require(try await encoder.prepareAll(fileURL: url).first)
        #expect(item.kind == .text && item.summary == "\(label): text extracted" && item.documentLabel == label && item.pageCount == nil)
        #expect(item.text?.hasPrefix("\(label): text extracted\n\nMARKER office text") == true && item.text?.contains("Zażółć gęślą jaźń") == true)
    }
    let long = NSAttributedString(string: (0..<400).map { "Paragraph \($0) of a long letter." }.joined(separator: "\n"))
    let url = folder.appending(path: "long.docx")
    try long.data(from: NSRange(location: 0, length: long.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
    var limits = DocumentLimits.standard; limits.textCharacters = 2_000
    let capped = try #require(try await encoder.prepareAll(fileURL: url, limits: limits).first)
    #expect(capped.summary == "DOCX: text extracted, truncated at 2000 characters" && (capped.text?.count ?? .max) < 2_100)
}

@Test func cancellationStopsBetweenPagesAndLeavesNoFiles() async throws {
    let (folder, encoder) = workspace()
    let url = try DocumentFixtures.write(DocumentFixtures.pdf((1...6).map { .text("MARKER page \($0) with enough words") }), name: "six.pdf", in: folder)
    let log = PageLog()
    let task = Task.detached {
        try await encoder.prepareAll(fileURL: url, pageHook: { page in
            log.add(page, main: Thread.isMainThread)
            if page == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(log.seen == [0, 1], "page 2 was never started")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "attachments").path)) ?? []).isEmpty)

    // Page images already rendered are not written once the read is cancelled.
    let scans = try DocumentFixtures.write(DocumentFixtures.pdf([.raster(words: nil, noise: true), .text("MARKER last text page")]), name: "scan.pdf", in: folder)
    var noOCR = DocumentLimits.standard; noOCR.ocrPages = 0
    let late = Task.detached { try await encoder.prepareAll(fileURL: scans, limits: noOCR, pageHook: { page in if page == 1 { withUnsafeCurrentTask { $0?.cancel() } } }) }
    _ = try? await late.value
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "attachments").path)) ?? []).isEmpty)
}

@Test @MainActor func readerRunsOffTheMainThreadAndTheStoreKeepsOrder() async throws {
    let (folder, encoder) = workspace()
    let url = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER threading page one text")]), name: "thread.pdf", in: folder)
    let log = PageLog()
    _ = try await encoder.prepareAll(fileURL: url, pageHook: { page in log.add(page, main: Thread.isMainThread) })
    #expect(log.onMain == [false], "called from the main actor, read on the generic executor")

    let store = AppStore(storeURL: folder.appending(path: "store.json"), autoConfigureHermes: false, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    let note = folder.appending(path: "a.txt"); try Data("first".utf8).write(to: note)
    let blob = folder.appending(path: "blob.bin"); try Data([0, 1, 0]).write(to: blob)
    let items = await store.prepareAttachmentsAsync([note, blob, url])
    #expect(items.map(\.name) == ["a.txt", "thread.pdf"], "a refused file is skipped, the rest keep their order")
    #expect(store.errorMessage == AttachmentError.unsupported("blob.bin").localizedDescription)
    #expect(store.prepareAttachments([note]).count == 1, "the synchronous API still works")
}

@Test func oldAndNewAttachmentJSONDecode() throws {
    let id = UUID()
    let old = #"{"id":"\#(id.uuidString)","kind":"text","name":"a.txt","mimeType":"text/plain","byteCount":2,"text":"hi"}"#
    let decoded = try JSONDecoder().decode(ChatAttachment.self, from: Data(old.utf8))
    #expect(decoded == ChatAttachment(id: id, kind: .text, name: "a.txt", mimeType: "text/plain", byteCount: 2, text: "hi"))
    #expect(decoded.pageCount == nil && decoded.summary == nil && !decoded.isDocument)
    let new = ChatAttachment(id: id, kind: .text, name: "r.pdf", mimeType: "application/pdf", byteCount: 9, text: "PDF: 2 pages", pageCount: 2, summary: "PDF: 2 pages, text extracted")
    let data = try JSONEncoder().encode(new)
    #expect(try JSONDecoder().decode(ChatAttachment.self, from: data) == new)
    // An older build's decoder (the P4 shape) ignores the extra fields.
    struct P4Attachment: Decodable { enum Kind: String, Decodable { case image, text }; let id: UUID; let kind: Kind; let name: String; let mimeType: String; let byteCount: Int; var fileName: String?; var text: String? }
    let legacy = try JSONDecoder().decode(P4Attachment.self, from: data)
    #expect(legacy.kind == .text && legacy.name == "r.pdf" && legacy.text == "PDF: 2 pages")
}

@Test func previewShowsAtMostTwentyThousandCharacters() {
    let text = String(repeating: "ab\n", count: 40_000)
    let shown = AttachmentPreview.capped(text)
    #expect(shown.text.count == 20_000 && shown.note == "Showing the first 20,000 of 120,000 characters.")
    #expect(AttachmentPreview.capped("short").note == nil)
    #expect(AttachmentPreview.symbol(for: ChatAttachment(id: UUID(), kind: .text, name: "a.pdf", mimeType: "application/pdf", byteCount: 1)) == "doc.richtext")
    #expect(AttachmentPreview.symbol(for: ChatAttachment(id: UUID(), kind: .text, name: "a.txt", mimeType: "text/plain", byteCount: 1)) == "doc.text")
}

extension DocumentReaderTests {
    @Test(.enabled(if: PageOCR.languages().polish, "Vision on this Mac lists no pl-PL model; the Polish OCR test did not run"))
    func polishOCRKeepsDiacritics() throws {
        let languages = PageOCR.languages()
        #expect(languages.languages.first == "pl-PL")
        let text = PageOCR.recognize(DocumentFixtures.raster(words: "ZAŻÓŁĆ GĘŚLĄ"), languages: languages.languages)
        #expect(text.contains("Ż") || text.contains("Ł") || text.contains("Ę"), "Polish letters survive OCR")
    }
}
