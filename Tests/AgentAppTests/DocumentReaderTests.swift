import Foundation
import PDFKit
import Testing
@testable import AgentApp

/// P19: PDFs (and RTF/DOCX) are read on the Mac. All fixtures are synthetic and written per test.
private func workspace() -> (folder: URL, encoder: AttachmentEncoder) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "AgentAppTests-docs-\(UUID().uuidString)")
    return (folder, AttachmentEncoder(directory: folder.appending(path: "attachments")))
}

private func attachmentFiles(_ folder: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "attachments").path)) ?? []
}

/// Serialized: Vision OCR and JPEG loops are CPU-heavy, and running them side by side starved the
/// main-actor timing budgets of unrelated tests (ui-smoke) in the parallel suite.
@Suite(.serialized) struct DocumentReaderTests {
    @Test func textPDFIsReadPageByPageWithASummaryFirst() async throws {
        let (folder, encoder) = workspace()
        let url = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER-ONE alpha beta gamma delta"), .text("MARKER-TWO epsilon zeta eta theta"), .text("MARKER-THREE iota kappa lambda mu")]), name: "report.pdf", in: folder)
        let items = try await encoder.prepareAll(fileURL: url)
        #expect(items.count == 1)
        let pdf = try #require(items.first)
        #expect(pdf.kind == .text && pdf.mimeType == "application/pdf" && pdf.pageCount == 3 && pdf.isDocument && pdf.documentLabel == "3 pages")
        #expect(pdf.summary == "PDF: 3 pages, text extracted")
        let text = try #require(pdf.text)
        #expect(text.hasPrefix("PDF: 3 pages, text extracted\n\n--- page 1 ---\n"))
        let one = try #require(text.range(of: "MARKER-ONE")), two = try #require(text.range(of: "--- page 2 ---\nMARKER-TWO")), three = try #require(text.range(of: "--- page 3 ---\nMARKER-THREE"))
        #expect(one.lowerBound < two.lowerBound && two.lowerBound < three.lowerBound)
        #expect(!text.contains("[truncated"))
        // The composed block the model sees starts with the file header, then the summary line.
        #expect(AttachmentEncoder.compose(text: "", attachments: [pdf]).hasPrefix("File: report.pdf\n```\nPDF: 3 pages, text extracted\n"))
        // A synchronous `prepare` still refuses documents (they need the reader).
        #expect(throws: AttachmentError.unsupported("report.pdf")) { try encoder.prepare(fileURL: url) }
    }

    @Test func pageAndCharacterCapsStopAtWholePagesWithAMarker() async throws {
        let (folder, encoder) = workspace()
        let long = try DocumentFixtures.write(DocumentFixtures.pdf((1...130).map { .text("MARKER \($0) short page text here") }), name: "long.pdf", in: folder)
        let capped = try #require(try await encoder.prepareAll(fileURL: long).first)
        #expect(capped.pageCount == 130 && capped.summary == "PDF: 130 pages, text extracted, truncated at page 100 of 130")
        #expect(capped.text?.hasSuffix("[truncated: pages 1–100 of 130]") == true)
        #expect(capped.text?.contains("--- page 100 ---") == true && capped.text?.contains("--- page 101 ---") == false)

        let pages = (1...6).map { FixturePage.text(DocumentFixtures.pageText("P\($0)", characters: 1_500)) }
        let wordy = try DocumentFixtures.write(DocumentFixtures.pdf(pages), name: "wordy.pdf", in: folder)
        var limits = DocumentLimits.standard; limits.textCharacters = 4_000
        let cut = try #require(try await encoder.prepareAll(fileURL: wordy, limits: limits).first)
        let body = try #require(cut.text?.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n"))
        #expect(body.count <= limits.textCharacters, "extracted text stays under the cap")
        #expect(cut.summary == "PDF: 6 pages, text extracted, truncated at page 2 of 6")
        #expect(body.hasSuffix("[truncated: pages 1–2 of 6]") && body.contains("MARKER P2") && !body.contains("MARKER P3"))

        // A first page larger than the cap is cut inside the page at a line break, still with the marker.
        limits.textCharacters = 600
        let first = try #require(try await encoder.prepareAll(fileURL: wordy, limits: limits).first?.text)
        let firstBody = first.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n")
        #expect(firstBody.count <= 600 && firstBody.contains("MARKER P1") && firstBody.hasSuffix("[truncated: pages 1–1 of 6]"))
        let lastLine = try #require(firstBody.components(separatedBy: "\n\n").first?.components(separatedBy: "\n").last)
        #expect(lastLine.hasSuffix("plain words."), "cut at a line break, not mid-line")
    }

    @Test func textlessHeuristicCatchesEmptyAndGarbledPages() {
        #expect(AttachmentDocumentReader.isTextless(""))
        #expect(AttachmentDocumentReader.isTextless("  12  \n 3 4 "))
        #expect(!AttachmentDocumentReader.isTextless("Invoice number 2026 for services"))
        #expect(AttachmentDocumentReader.isTextless(String(repeating: "\u{FFFD}", count: 40) + "abcdefghijklmnopqrst"), "over 30% U+FFFD")
        #expect(AttachmentDocumentReader.isTextless(String(repeating: "\u{0001}", count: 20) + "abcdefghijklmnopqrst"), "over 30% control characters")
        #expect(!AttachmentDocumentReader.isTextless(String(repeating: "\u{FFFD}", count: 5) + "abcdefghijklmnopqrstuvwxyz"), "a few bad characters are fine")
    }

    @Test func scannedPageIsReadByVisionOCR() async throws {
        let (folder, encoder) = workspace()
        let url = try DocumentFixtures.write(DocumentFixtures.pdf([.raster(words: "INVOICE 2026\nTOTAL DUE 42")]), name: "scan.pdf", in: folder)
        let started = Date()
        let items = try await encoder.prepareAll(fileURL: url)
        print("P19 OCR: one 612×792 pt page in \(String(format: "%.2f", Date().timeIntervalSince(started))) s; pl-PL available: \(PageOCR.languages().polish)")
        let pdf = try #require(items.first)
        // If Vision returned nothing here the page would come back as an image instead; that must fail, not pass.
        #expect(items.count == 1, "OCR found text, so no page image")
        #expect(pdf.text?.uppercased().contains("INVOICE") == true && pdf.text?.contains("2026") == true)
        #expect(pdf.summary?.hasPrefix("PDF: 1 page, 1 page read by OCR") == true)
    }

    @Test func rotatedPagesRenderUprightForOCR() async throws {
        let (folder, encoder) = workspace()
        let data = DocumentFixtures.rotated(DocumentFixtures.pdf([.raster(words: "INVOICE 2026\nTOTAL DUE 42")]), page: 0, degrees: 90)
        #expect(PDFDocument(data: data)?.page(at: 0)?.rotation == 90)
        let pageRef = try #require(PDFDocument(data: data)?.page(at: 0)?.pageRef)
        let image = try #require(PageOCR.render(pageRef, maxEdge: 1000))
        #expect(image.width > image.height, "a 90° page renders landscape")
        #expect(max(image.width, image.height) <= 1000)
        let url = try DocumentFixtures.write(data, name: "rotated.pdf", in: folder)
        #expect(try await encoder.prepareAll(fileURL: url).first?.text?.uppercased().contains("INVOICE") == true)
    }

    @Test func mixedPDFKeepsTextPagesAndOCRsTheScan() async throws {
        let (folder, encoder) = workspace()
        let url = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER-TEXT page with a real text layer"), .raster(words: "INVOICE 2026\nTOTAL DUE 42")]), name: "mixed.pdf", in: folder)
        let pdf = try #require(try await encoder.prepareAll(fileURL: url).first)
        #expect(pdf.summary?.hasPrefix("PDF: 2 pages, text extracted, 1 page read by OCR") == true)
        #expect(pdf.text?.contains("MARKER-TEXT") == true && pdf.text?.uppercased().contains("INVOICE") == true)
    }

    @Test func ocrAndImageCapsAreHonouredAndImagesStayUnderTheBound() async throws {
        let (folder, encoder) = workspace()
        let url = try DocumentFixtures.write(DocumentFixtures.pdf([.raster(words: "INVOICE 2026\nTOTAL DUE 42"), .raster(words: "INVOICE 2027\nTOTAL DUE 43"), .raster(words: nil, noise: true), .raster(words: nil, noise: true)]), name: "scans.pdf", in: folder)
        var limits = DocumentLimits.standard; limits.ocrPages = 1; limits.pageImages = 2
        let items = try await encoder.prepareAll(fileURL: url, limits: limits)
        #expect(items.count == 3, "text first, then two page images")
        #expect(items.dropFirst().map(\.name) == ["scans — page 2.jpg", "scans — page 3.jpg"])
        #expect(items.dropFirst().allSatisfy { $0.kind == .image && $0.mimeType == "image/jpeg" && $0.byteCount <= DocumentLimits.standard.pageImageBytes })
        #expect(items[0].summary == "PDF: 4 pages, 1 page read by OCR, OCR limit reached, 3 more scanned pages, 2 pages sent as images, 1 unreadable page not sent")
        #expect(attachmentFiles(folder).count == 2)
        // A bound no JPEG can meet skips the image and counts it.
        let mixed = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER text page before the noise"), .raster(words: nil, noise: true)]), name: "noise.pdf", in: folder)
        limits.pageImageBytes = 2_000; limits.ocrPages = 0
        let skipped = try await encoder.prepareAll(fileURL: mixed, limits: limits)
        #expect(skipped.count == 1 && skipped[0].summary?.hasSuffix("1 unreadable page not sent") == true)
    }

    @Test func lockedNoTextAndCopyRestrictedOutcomes() async throws {
        let (folder, encoder) = workspace()
        let plain = try #require(PDFDocument(data: DocumentFixtures.pdf([.text("MARKER secret page with words")])))
        let lockedURL = folder.appending(path: "locked.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(plain.write(to: lockedURL, withOptions: [.userPasswordOption: "user-pw", .ownerPasswordOption: "owner-pw"]))
        await #expect(throws: AttachmentError.locked("locked.pdf")) { try await encoder.prepareAll(fileURL: lockedURL) }
        #expect(AttachmentError.locked("locked.pdf").localizedDescription == "“locked.pdf” is password-protected. Remove the password and attach it again.")

        var noImages = DocumentLimits.standard; noImages.pageImages = 0
        let blank = try DocumentFixtures.write(DocumentFixtures.pdf([.blank]), name: "blank.pdf", in: folder)
        await #expect(throws: AttachmentError.noText("blank.pdf")) { try await encoder.prepareAll(fileURL: blank, limits: noImages) }

        // Copy restriction is advisory: the text is read anyway and the summary says so.
        let restricted: [CFString: Any] = [kCGPDFContextOwnerPassword: "owner-pw", kCGPDFContextAllowsCopying: false]
        let copyURL = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER restricted statement text")], auxiliary: restricted), name: "statement.pdf", in: folder)
        #expect(PDFDocument(url: copyURL)?.allowsCopying == false && PDFDocument(url: copyURL)?.isLocked == false)
        let copied = try #require(try await encoder.prepareAll(fileURL: copyURL).first)
        #expect(copied.summary == "PDF: 1 page, text extracted (copy-restricted file)" && copied.text?.contains("MARKER restricted") == true)
        let emptyRestricted = try DocumentFixtures.write(DocumentFixtures.pdf([.blank], auxiliary: restricted), name: "empty.pdf", in: folder)
        await #expect(throws: AttachmentError.copyRestricted("empty.pdf")) { try await encoder.prepareAll(fileURL: emptyRestricted, limits: noImages) }
    }

    @Test func sourceCapAndMisnamedPDFAndUnchangedRefusals() async throws {
        let (folder, encoder) = workspace()
        let huge = folder.appending(path: "huge.pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: huge.path, contents: Data("%PDF-1.4\n".utf8))
        let handle = try FileHandle(forWritingTo: huge); try handle.truncate(atOffset: 50 * 1024 * 1024 + 1); try handle.close()
        await #expect(throws: AttachmentError.tooLarge("huge.pdf", "50 MB")) { try await encoder.prepareAll(fileURL: huge) }
        var small = DocumentLimits.standard; small.sourceBytes = 1_048_576
        let misnamed = try DocumentFixtures.write(DocumentFixtures.pdf([.text("MARKER misnamed document body")]), name: "scan.dat", in: folder)
        let detected = try #require(try await encoder.prepareAll(fileURL: misnamed, limits: small).first)
        #expect(detected.mimeType == "application/pdf" && detected.text?.contains("MARKER misnamed") == true)
        // Images, text files and binaries behave as before.
        let binary = folder.appending(path: "blob.bin"); try Data([0, 1, 2, 0, 255]).write(to: binary)
        await #expect(throws: AttachmentError.unsupported("blob.bin")) { try await encoder.prepareAll(fileURL: binary) }
        let note = folder.appending(path: "note.txt"); try Data("line one\n".utf8).write(to: note)
        let viaAll = try await encoder.prepareAll(fileURL: note)
        #expect(viaAll.count == 1 && viaAll[0].kind == .text && viaAll[0].text == "line one\n" && viaAll[0].pageCount == nil && viaAll[0].summary == nil)
        let big = folder.appending(path: "big.txt"); try Data(repeating: 65, count: AttachmentEncoder.maxTextBytes + 1).write(to: big)
        await #expect(throws: AttachmentError.tooLarge("big.txt", "200 KB")) { try await encoder.prepareAll(fileURL: big) }
        #expect(AttachmentError.unsupported("x").localizedDescription.contains("PNG, JPEG, GIF, WebP, PDF, RTF, DOC, DOCX and text files (text up to 200 KB)"))
    }
}
