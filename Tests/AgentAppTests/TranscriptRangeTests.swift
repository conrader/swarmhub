import Foundation
import Testing
@testable import AgentApp

struct TranscriptRangeTests {
    @Test func partialRunsAreSymmetricAndKeepUnicodeIntact() {
        let row = TranscriptRowID.message(UUID())
        let order = [row: 0]
        let text = "L👩🏾‍💻 café R" as NSString
        let expected = text.range(of: "👩🏾‍💻 café")
        let first = TranscriptRange.Point(row: row, offset: expected.location)
        let last = TranscriptRange.Point(row: row, offset: NSMaxRange(expected))
        for range in [TranscriptRange(anchor: first, head: last), TranscriptRange(anchor: last, head: first)] {
            #expect(range.slice(row: row, extent: NSRange(location: 0, length: text.length), order: order) == expected)
            #expect(range.slice(row: row, extent: NSRange(location: text.length + 1, length: 3), order: order) == nil)
        }
    }

    @Test func finishingInlineMarkdownKeepsTheSelectedCharacters() {
        let row = TranscriptRowID.message(UUID())
        var range = TranscriptRange(anchor: .init(row: row, offset: 10), head: .init(row: row, offset: 6))
        range.rebase(row: row, from: "See **bold", to: "See bold and more")
        #expect(range.head.offset == 4 && range.anchor.offset == 8)
        range.rebase(row: row, from: "See bold and more", to: "See bold and more yet")
        #expect(range.head.offset == 4 && range.anchor.offset == 8)
    }

    @Test func historyInsertionAndStreamingKeepBothEndpointsAcrossThousandsOfRows() {
        let rows = (0..<3017).map { _ in TranscriptRowID.message(UUID()) }
        let history = TranscriptRowID.history("archive")
        let order = Dictionary(uniqueKeysWithValues: ([history] + rows).enumerated().map { ($0.element, $0.offset) })
        let first = TranscriptRange.Point(row: rows[0], offset: 7)
        let last = TranscriptRange.Point(row: rows[3016], offset: 3)
        let selection = TranscriptRange(anchor: last, head: first)
        let run = NSRange(location: 0, length: 24)
        #expect(selection.slice(row: rows[0], extent: run, order: order) == NSRange(location: 7, length: 17))
        for row in rows.dropFirst().dropLast() { #expect(selection.slice(row: row, extent: run, order: order) == run) }
        #expect(selection.slice(row: rows[3016], extent: NSRange(location: 1, length: 900), order: order) == NSRange(location: 1, length: 2))
        #expect(selection.slice(row: history, extent: run, order: order) == nil)
        #expect(selection.slice(row: rows[0], extent: run, order: [rows[0]: 0]) == nil)
    }
}
