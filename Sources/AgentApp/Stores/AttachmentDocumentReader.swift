import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Documents read on the Mac. Hermes accepts no file parts (0.20.5 through 0.22.0 answer 400
/// `unsupported_content_type`), so a document's text goes out as ordinary text.
enum DocumentKind: String, Sendable, CaseIterable {
    case pdf, rtf, doc, docx
    var mimeType: String {
        switch self {
        case .pdf: "application/pdf"
        case .rtf: "application/rtf"
        case .doc: "application/msword"
        case .docx: "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        }
    }
    var label: String { rawValue.uppercased() }
    init?(mimeType: String) {
        guard let kind = Self.allCases.first(where: { $0.mimeType == mimeType }) else { return nil }
        self = kind
    }

    /// By type (`.pdf`, `.rtf`, `doc`, `docx` by extension) or by a `%PDF-` header in the first 1,024 bytes.
    static func detect(_ url: URL) -> DocumentKind? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true { return .pdf }
        if type?.conforms(to: .rtf) == true { return .rtf }
        switch url.pathExtension.lowercased() {
        case "doc": return .doc
        case "docx": return .docx
        default: break
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        return head.range(of: Data("%PDF-".utf8)) != nil ? .pdf : nil
    }
}

/// Limits of the document branch; constants by default, smaller in tests.
struct DocumentLimits: Sendable {
    var sourceBytes = 50 * 1024 * 1024
    var textCharacters = 120_000
    var pages = 100
    var ocrPages = 20
    var pageImages = 4
    var pageImageBytes = 700 * 1024
    static let standard = DocumentLimits()
}

/// What the reader hands back: Sendable values only (no PDFKit objects leave the reader).
struct DocumentExtraction: Sendable {
    struct PageImage: Sendable { let page: Int; let jpeg: Data }
    var kind: DocumentKind
    var text = ""
    var summary = ""
    var pageCount: Int?
    var pagesRead = 0
    var textPages = 0
    var ocrPages = 0
    var ocrAttempts = 0
    var ocrSkipped = 0
    var images: [PageImage] = []
    var imagesSkipped = 0
    var copyRestricted = false
    var polishOCR: Bool?
    var truncated = false
    var characterCount: Int { text.count }
}

enum AttachmentDocumentReader {
    /// Called before each page with its zero-based index; tests use it to cancel or to see the thread.
    typealias PageHook = @Sendable (Int) throws -> Void

    static func read(_ url: URL, kind: DocumentKind, name: String, limits: DocumentLimits = .standard, pageHook: PageHook? = nil) throws -> DocumentExtraction {
        try Task.checkCancellation()
        return kind == .pdf ? try readPDF(url, name: name, limits: limits, pageHook: pageHook) : try readText(url, kind: kind, name: name, limits: limits)
    }

    // MARK: PDF

    private static func readPDF(_ url: URL, name: String, limits: DocumentLimits, pageHook: PageHook?) throws -> DocumentExtraction {
        guard let document = PDFDocument(url: url) else { throw AttachmentError.unreadable(name) }
        // PDFKit tries the empty password itself, so owner-password-only files arrive unlocked.
        guard !document.isLocked else { throw AttachmentError.locked(name) }
        var result = DocumentExtraction(kind: .pdf, pageCount: document.pageCount)
        // `allowsCopying` is advisory: the user chose this file, so it is read anyway and the summary says so.
        result.copyRestricted = !document.allowsCopying
        let marker = "[truncated: pages 1–%d of \(document.pageCount)]"
        let budget = limits.textCharacters - marker.count - 8
        var body = ""; var bodyCount = 0
        for index in 0..<document.pageCount {
            guard index < limits.pages else { result.truncated = true; break }
            try Task.checkCancellation(); try pageHook?(index)
            guard let pageText = try autoreleasepool(invoking: { try pageText(document, index: index, limits: limits, result: &result) }) else { continue }
            let block = (body.isEmpty ? "" : "\n\n") + "--- page \(index + 1) ---\n" + pageText
            if bodyCount + block.count > budget {
                result.truncated = true
                if index == 0 {
                    body = cut(block, to: budget); bodyCount = body.count; result.pagesRead = 1
                }
                break
            }
            body += block; bodyCount += block.count; result.pagesRead = index + 1
        }
        if result.truncated { body += "\n\n" + String(format: marker, result.pagesRead) }
        if result.textPages == 0 && result.ocrPages == 0 && result.images.isEmpty {
            throw result.copyRestricted ? AttachmentError.copyRestricted(name) : AttachmentError.noText(name)
        }
        result.summary = pdfSummary(result)
        result.text = result.summary + "\n\n" + body
        return result
    }

    /// The page's own text, or OCR text, or a page image (then a note in place of the text); nil skips the page.
    private static func pageText(_ document: PDFDocument, index: Int, limits: DocumentLimits, result: inout DocumentExtraction) throws -> String? {
        guard let page = document.page(at: index) else { return nil }
        let own = page.string ?? ""
        if !isTextless(own) { result.textPages += 1; return own.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let pageRef = page.pageRef else { return "[no readable text on this page]" }
        if result.ocrAttempts < limits.ocrPages {
            result.ocrAttempts += 1
            let ocr = PageOCR.recognize(pageRef)
            result.polishOCR = ocr.polish
            if nonWhitespaceCount(ocr.text) >= 16 { result.ocrPages += 1; return ocr.text }
        } else { result.ocrSkipped += 1 }
        guard result.images.count < limits.pageImages else { result.imagesSkipped += 1; return "[no readable text on this page]" }
        guard let jpeg = PageOCR.pageJPEG(pageRef, maxBytes: limits.pageImageBytes) else { result.imagesSkipped += 1; return "[no readable text on this page]" }
        result.images.append(.init(page: index + 1, jpeg: jpeg))
        return "[page sent as an image]"
    }

    /// Textless: fewer than 16 non-whitespace characters, or over 30% U+FFFD or control characters.
    /// A wrong-but-valid text layer is not caught.
    static func isTextless(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        guard scalars.count >= 16 else { return true }
        let bad = scalars.filter { $0.value == 0xFFFD || CharacterSet.controlCharacters.contains($0) }.count
        return Double(bad) > Double(scalars.count) * 0.3
    }

    static func nonWhitespaceCount(_ text: String) -> Int { text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count }

    /// Cuts at the last line break within `limit` characters, else at `limit`.
    static func cut(_ text: String, to limit: Int) -> String {
        let prefix = text.prefix(limit)
        guard let newline = prefix.lastIndex(of: "\n"), newline > prefix.startIndex else { return String(prefix) }
        return String(prefix[..<newline])
    }

    static func pdfSummary(_ result: DocumentExtraction) -> String {
        let pages = result.pageCount ?? 0
        var parts = ["PDF: \(pages == 1 ? "1 page" : "\(pages) pages")"]
        if result.textPages > 0 { parts.append("text extracted") }
        if result.ocrPages > 0 {
            parts.append("\(result.ocrPages == 1 ? "1 page" : "\(result.ocrPages) pages") read by OCR" + (result.polishOCR == false ? " (no Polish model, accents may be wrong)" : ""))
        }
        if result.ocrSkipped > 0 { parts.append("OCR limit reached, \(result.ocrSkipped) more scanned \(result.ocrSkipped == 1 ? "page" : "pages")") }
        if !result.images.isEmpty { parts.append("\(result.images.count == 1 ? "1 page" : "\(result.images.count) pages") sent as images") }
        if result.imagesSkipped > 0 { parts.append("\(result.imagesSkipped) unreadable \(result.imagesSkipped == 1 ? "page" : "pages") not sent") }
        if result.truncated { parts.append("truncated at page \(result.pagesRead) of \(pages)") }
        return parts.joined(separator: ", ") + (result.copyRestricted ? " (copy-restricted file)" : "")
    }

    // MARK: RTF, DOC, DOCX

    /// Plain text only (`.string`), through an explicit document type; never HTML, web archives or RTFD.
    private static func readText(_ url: URL, kind: DocumentKind, name: String, limits: DocumentLimits) throws -> DocumentExtraction {
        let type: NSAttributedString.DocumentType = switch kind {
        case .rtf: .rtf
        case .doc: .docFormat
        default: .officeOpenXML
        }
        guard let attributed = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) else { throw AttachmentError.unreadable(name) }
        var text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard nonWhitespaceCount(text) > 0 else { throw AttachmentError.noText(name) }
        var result = DocumentExtraction(kind: kind)
        if text.count > limits.textCharacters {
            text = cut(text, to: limits.textCharacters - 64) + "\n\n[truncated: first \(limits.textCharacters) characters]"
            result.truncated = true
        }
        result.summary = "\(kind.label): text extracted" + (result.truncated ? ", truncated at \(limits.textCharacters) characters" : "")
        result.text = result.summary + "\n\n" + text
        return result
    }
}
