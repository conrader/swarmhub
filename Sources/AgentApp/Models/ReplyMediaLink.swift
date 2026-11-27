import Foundation

/// A local media destination explicitly linked in Markdown prose. Foundation has already resolved
/// escapes and distinguished code from links, without changing transcript offsets or card indexes.
struct ReplyMediaLink: Identifiable {
    let url: URL
    let title: String
    var id: URL { url }

    static func fileURL(_ url: URL) -> URL? {
        guard url.scheme == nil || url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, !url.absoluteString.hasPrefix("//") else { return nil }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\0"),
              ChatMediaKind(filename: path) != nil else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func links(in blocks: [TranscriptText.Prose]) -> [Self] {
        var seen = Set<URL>(), result: [Self] = []
        func collect(_ run: TranscriptText.Run) {
            for span in run.value.runs {
                guard let link = span.link ?? span.imageURL, let url = fileURL(link), seen.insert(url).inserted else { continue }
                let label = String(run.value[span.range].characters)
                result.append(Self(url: url, title: label.isEmpty ? url.lastPathComponent : label))
            }
        }
        func visit(_ blocks: [TranscriptText.Prose]) {
            for block in blocks {
                switch block {
                case .paragraph(let run), .heading(_, let run): collect(run)
                case .quote(let children): visit(children)
                case .list(let items): for item in items { collect(item.text) }
                case .table(let rows): for row in rows { row.forEach(collect) }
                case .rule: break
                }
            }
        }
        visit(blocks)
        return result
    }
}
