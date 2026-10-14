import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
@testable import AgentApp

/// Server limits the P19 splitter and body guard stay under, read from `~/code/hermes-ref`
/// `gateway/platforms/api_server.py`: v2026.8.19 (= the box's 0.20.5) lines 154/156/157, v0.21.7 and v0.22.0
/// lines 233/239/240. If upstream changes them, this is the one place to change.
enum HermesServerLimits {
    /// `MAX_NORMALIZED_TEXT_LENGTH`: every text part and plain string is cut here (Python `len`, code points).
    static let maxNormalizedTextLength = 65_536
    /// `MAX_REQUEST_BYTES`: aiohttp `client_max_size`, a 413 above it.
    static let maxRequestBytes = 10_000_000
    /// `MAX_CONTENT_LIST_SIZE`: parts beyond it are dropped.
    static let maxContentListSize = 1_000
}

/// One page of a synthetic PDF.
enum FixturePage {
    /// Text drawn with CoreText (a real text layer), `size` points.
    case text(String, fontSize: CGFloat = 10)
    /// A bitmap only, no text layer: large black words on white (a "scan") or noise.
    case raster(words: String?, noise: Bool = false)
    case blank
}

/// Synthetic PDFs written with a CoreGraphics PDF context; nothing is checked in.
enum DocumentFixtures {
    static let pageSize = CGSize(width: 612, height: 792)

    static func pdf(_ pages: [FixturePage], auxiliary: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, auxiliary as CFDictionary)!
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text, let fontSize): drawText(text, fontSize: fontSize, in: context)
            case .raster(let words, let noise): context.draw(raster(words: words, noise: noise), in: box)
            case .blank: break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func write(_ data: Data, name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name); try data.write(to: url); return url
    }

    /// `pdf` with page `index` rotated by `degrees` (PDFKit sets the page's /Rotate).
    static func rotated(_ data: Data, page index: Int, degrees: Int) -> Data {
        let document = PDFDocument(data: data)!
        document.page(at: index)!.rotation = degrees
        return document.dataRepresentation()!
    }

    private static func drawText(_ text: String, fontSize: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 36, y: 36, width: pageSize.width - 72, height: pageSize.height - 72), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
    }

    /// A white bitmap with `words` in 72 pt black (or seeded noise), at 2× the page size.
    static func raster(words: String?, noise: Bool = false) -> CGImage {
        let width = Int(pageSize.width * 2), height = Int(pageSize.height * 2)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt32 = 987
            for index in 0..<(context.bytesPerRow * height) { seed = seed &* 1103515245 &+ 12345; pixels[index] = UInt8(truncatingIfNeeded: seed >> 16) }
        }
        if let words {
            // 72 pt at 2× scale, one line per `\n`.
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 144, nil)
            for (index, text) in words.components(separatedBy: "\n").enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]))
                context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 300 - CGFloat(index) * 220); CTLineDraw(line, context)
            }
        }
        return context.makeImage()!
    }

    /// Distinct, line-broken text of about `characters` characters with a page marker.
    static func pageText(_ marker: String, characters: Int) -> String {
        var lines = ["MARKER \(marker)"]; var count = lines[0].count
        var n = 0
        while count < characters { let line = "Line \(n) of page \(marker) with plain words."; lines.append(line); count += line.count + 1; n += 1 }
        return lines.joined(separator: "\n")
    }
}
