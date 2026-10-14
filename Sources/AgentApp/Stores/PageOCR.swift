import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// On-device OCR and page images for scanned PDF pages. Pages are drawn through CGPDF (crop box, the page's
/// own rotation applied by `getDrawingTransform`) into a white bitmap of exact size. Synchronous: the
/// reader calls it off the main actor, one page at a time.
enum PageOCR {
    /// Long edge for OCR (about 2× point size) and for the page-image fallback.
    static let ocrEdge: CGFloat = 3000, imageEdge: CGFloat = 1600

    /// Recognition languages: Polish, English and the user's locale when Vision has a Polish model; otherwise
    /// automatic detection, reported as `polish == false`.
    static func languages() -> (languages: [String], polish: Bool) {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        guard supported.contains("pl-PL") else { return ([], false) }
        var wanted: [String] = []
        for code in ["pl-PL", "en-US", Locale.current.identifier(.bcp47)] where supported.contains(code) && !wanted.contains(code) { wanted.append(code) }
        return (wanted, true)
    }

    /// Text lines top to bottom, then left to right.
    static func recognize(_ page: CGPDFPage) -> (text: String, polish: Bool) {
        let (languages, polish) = Self.languages()
        guard let image = render(page, maxEdge: ocrEdge) else { return ("", polish) }
        return (recognize(image, languages: languages), polish)
    }

    static func recognize(_ image: CGImage, languages: [String]) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        if languages.isEmpty { request.automaticallyDetectsLanguage = true }
        else { request.automaticallyDetectsLanguage = false; request.recognitionLanguages = languages }
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return "" }
        let observations = (request.results ?? []).sorted { a, b in
            let rowA = Int(((1 - a.boundingBox.midY) * 100).rounded()), rowB = Int(((1 - b.boundingBox.midY) * 100).rounded())
            return rowA != rowB ? rowA < rowB : a.boundingBox.minX < b.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// The page in a white bitmap whose long edge is at most `maxEdge` pixels (and at most 2× point size).
    static func render(_ page: CGPDFPage, maxEdge: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let quarter = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = quarter == 90 || quarter == 270 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(2, maxEdge / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded(.down))), height = max(1, Int((size.height * scale).rounded(.down)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // The target rect equals the rotated box, so the transform only rotates and moves the crop origin.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// A JPEG of the page within `maxBytes`: quality 0.7, 0.5, 0.35, then a smaller edge; nil when it cannot fit.
    static func pageJPEG(_ page: CGPDFPage, maxBytes: Int, maxEdge: CGFloat = imageEdge) -> Data? {
        var edge = maxEdge
        while edge >= 320 {
            if let image = render(page, maxEdge: edge) {
                for quality in [0.7, 0.5, 0.35] {
                    if let data = AttachmentEncoder.encode(image, as: .jpeg, quality: quality), data.count <= maxBytes { return data }
                }
            }
            edge = (edge * 0.75).rounded(.down)
        }
        return nil
    }
}
