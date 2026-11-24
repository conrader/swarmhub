import AppKit
import SwiftUI
import Testing
@testable import AgentApp

@Suite struct MarkdownBlockParserTests {
    @Test func assistantReplyBreaksAtMarkersWithSingleNewlines() {
        let text = """
        ### 1. **Przegląd**
        > Patryk: *Zażółć gęślą jaźń*.
        >
        > Sprawdź [raport](https://example.com/raport?q=1) i `swift test`.
        > + **Wniosek**: gotowe.
        ---
        ### 2. Plan ###
        - **Bold**: pierwsza pozycja
        - **Bold**: druga pozycja
        """
        #expect(MarkdownBlockParser.parse(text) == [
            .heading(level: 3, text: "1. **Przegląd**"),
            .quote([
                .paragraph("Patryk: *Zażółć gęślą jaźń*."),
                .paragraph("Sprawdź [raport](https://example.com/raport?q=1) i `swift test`."),
                .list([.init(number: nil, depth: 0, text: "**Wniosek**: gotowe.")]),
            ]),
            .rule,
            .heading(level: 3, text: "2. Plan"),
            .list([
                .init(number: nil, depth: 0, text: "**Bold**: pierwsza pozycja"),
                .init(number: nil, depth: 0, text: "**Bold**: druga pozycja"),
            ]),
        ])
    }

    @Test func atxHeadingLevelsAndClosers() {
        let text = "# One\n## **Two**\nThe next line\n### Three ###\n#### Four\n##### Five\n###### C#\n####### Seven\n#hashtag"
        #expect(MarkdownBlockParser.parse(text) == [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "**Two**"),
            .paragraph("The next line"),
            .heading(level: 3, text: "Three"),
            .heading(level: 4, text: "Four"),
            .heading(level: 5, text: "Five"),
            .heading(level: 6, text: "C#"),
            .paragraph("####### Seven\n#hashtag"),
        ])
    }

    @Test func rulesTakePrecedenceOverBullets() {
        let text = "First\r\n---\r\n* * *\r\n____\r\n  - - - -  \r\n- * -\r\n- -"
        #expect(MarkdownBlockParser.parse(text) == [
            .paragraph("First"), .rule, .rule, .rule, .rule,
            .list([.init(number: nil, depth: 0, text: "* -"), .init(number: nil, depth: 0, text: "-")]),
        ])
    }

    @Test func mixedBulletMarkersNestingAndContinuations() {
        let text = "Start\n- **Root**\n   Ciąg dalszy\n  * Child\n    `x-y` stays\n    + Grandchild\n  - Child\n- Root\nEnding"
        #expect(MarkdownBlockParser.parse(text) == [
            .paragraph("Start"),
            .list([
                .init(number: nil, depth: 0, text: "**Root**\nCiąg dalszy"),
                .init(number: nil, depth: 1, text: "Child\n`x-y` stays"),
                .init(number: nil, depth: 2, text: "Grandchild"),
                .init(number: nil, depth: 1, text: "Child"),
                .init(number: nil, depth: 0, text: "Root"),
            ]),
            .paragraph("Ending"),
        ])
    }

    @Test func orderedListsKeepSourceNumbersAndAllowIndentedItems() {
        let text = "  9. *Nine*\n  12. Skipped ahead\n    More text\n\t- Nested\n  003. Repeat\n  + Separate"
        #expect(MarkdownBlockParser.parse(text) == [
            .list([
                .init(number: "9", depth: 0, text: "*Nine*"),
                .init(number: "12", depth: 0, text: "Skipped ahead\nMore text"),
                .init(number: nil, depth: 1, text: "Nested"),
                .init(number: "003", depth: 0, text: "Repeat"),
            ]),
            .list([.init(number: nil, depth: 0, text: "Separate")]),
        ])
    }

    @Test func quoteSpacersAndNestedQuotes() {
        let text = "> First line\n>second line\n>\n>> Nested\n  > Back\nOutside"
        #expect(MarkdownBlockParser.parse(text) == [
            .quote([.paragraph("First line\nsecond line"), .quote([.paragraph("Nested")]), .paragraph("Back")]),
            .paragraph("Outside"),
        ])
        let deep = MarkdownBlockParser.parse(String(repeating: ">", count: 4_096) + " Done")
        var expected: [MarkdownBlock] = [.paragraph("Done")]
        for _ in 0..<8 { expected = [.quote(expected)] }
        #expect(deep == expected)
    }

    @Test func tablesKeepInlineMarkdownAndEscapedPipes() {
        let text = #"""
        A paragraph
        | **Nazwa** | Wynik |
        | --- | :---: |
        | [Łącze](https://example.com) | `a\|b` |
        | puste | |
        #### Dalej
        """#
        #expect(MarkdownBlockParser.parse(text) == [
            .paragraph("A paragraph"),
            .table(header: ["**Nazwa**", "Wynik"], rows: [
                ["[Łącze](https://example.com)", "`a|b`"],
                ["puste", ""],
            ]),
            .heading(level: 4, text: "Dalej"),
        ])
    }

    @Test func partialTablesPreserveProseAndCompletedRows() {
        let header = "| A | B |"
        for malformed in ["|", "| --- |", "|---|--", "| --- | x |", "|---|---|---|"] {
            #expect(MarkdownBlockParser.parse(header + "\n" + malformed) == [.paragraph(header + "\n" + malformed)])
        }
        let prefix = header + "\n|---|---|\n| one | two |\n"
        let partial = "| three |"
        #expect(MarkdownBlockParser.parse(prefix + partial) == [
            .table(header: ["A", "B"], rows: [["one", "two"]]),
            .paragraph(partial),
        ])
        #expect(MarkdownBlockParser.parse(prefix + partial + " four |") == [
            .table(header: ["A", "B"], rows: [["one", "two"], ["three", "four"]]),
        ])
    }

    @Test func incompleteMarkersAndDuplicateLines() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse(" \t\n\n ").isEmpty)
        #expect(MarkdownBlockParser.parse("##\n-\n1.\n|\n`unfinished") == [.paragraph("##\n-\n1.\n|\n`unfinished")])
        #expect(MarkdownBlockParser.parse("Same\nSame\n \t\nSame") == [.paragraph("Same\nSame"), .paragraph("Same")])
        let item = MarkdownListItem(number: nil, depth: 0, text: "Same")
        #expect(MarkdownBlockParser.parse("- Same\n- Same") == [.list([item, item])])
    }

    @Test func proseIndentationSurvivesCardAndSwarmhubExtraction() throws {
        let source = """
        ```swarmhub
        {"op":"request_bot"}
        ```
          1. First
          2. Second

        ```swift
        # raw code
        ```
        ![chart](https://example.com/chart.png)
        ```draft
        Review this
        ```
        <!-- choices -->
        1. Accept
        2. Decline
        """
        let visible = SwarmhubBlock.visibleText(source, preservingWhitespace: true)
        let blocks = ChatCardParser.parse(visible, preservingProseWhitespace: true)
        let first = try #require(blocks.first)
        guard case .markdown(let prose) = first else { Issue.record("Expected opening prose"); return }
        #expect(MarkdownBlockParser.parse(prose) == [
            .list([.init(number: "1", depth: 0, text: "First"), .init(number: "2", depth: 0, text: "Second")]),
        ])
        #expect(Array(blocks.dropFirst()) == [
            .code(language: "swift", body: "# raw code"),
            .image(alt: "chart", url: "https://example.com/chart.png"),
            .draft(.init(body: "Review this")),
            .choices(prompt: "", options: ["Accept", "Decline"]),
        ])
        #expect(SwarmhubSummary.lines(in: source).count == 1)
    }

    @Test @MainActor func renderedTableGrowsToFitWrappedCells() {
        _ = NSApplication.shared
        func height(status: String) -> CGFloat {
            let text = "| Owner | Status |\n| --- | --- |\n| Morgan | \(status) |\n| Charles | Under review |"
            return NSHostingView(rootView: ProseBlock(text: text).frame(width: 440)).fittingSize.height
        }
        let singleLine = height(status: "**Approved**")
        let wrapped = height(status: "**Approved**, pending one final confirmation from the rest of the team.")
        #expect(singleLine > 0)
        #expect(wrapped > singleLine)
    }
}
