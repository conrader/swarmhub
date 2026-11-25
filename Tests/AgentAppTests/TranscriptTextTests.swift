import Foundation
import Testing
@testable import AgentApp

enum SelectionFixture {
    static let markdown = """
    ## Findings

    - **Alpha** checks the queue
    - Beta checks [the log](https://example.invalid/private-target)

    ```swift
    let count = 2
    ```

    | Owner | State |
    | --- | --- |
    | Ada | Ready |

    ```swarmhub
    {"unrecognized":"private control payload"}
    ```
    """
    static let visible = "Findings\n\n• Alpha checks the queue\n• Beta checks the log\n\nlet count = 2\n\nOwner\tState\nAda\tReady"
}

struct TranscriptTextTests {
    @Test func renderedRunsIndexTheExactClipboardText() throws {
        let projection = TranscriptText(reply: SelectionFixture.markdown, segments: nil)
        #expect(projection.string == SelectionFixture.visible)
        let string = projection.string as NSString
        func check(_ run: TranscriptText.Run) {
            let plain = String(run.value.characters)
            #expect(string.substring(with: .init(location: run.offset, length: plain.utf16.count)) == plain)
        }
        for block in projection.parts[0] {
            for prose in block.prose {
                switch prose {
                case .heading(_, let run): check(run)
                case .list(let items): for item in items { check(item.marker); check(item.text) }
                case .table(let rows): for run in rows.flatMap({ $0 }) { check(run) }
                default: Issue.record("Unexpected fixture block")
                }
            }
            if let run = block.run { check(run) }
        }
    }

    @Test func orderedStepsAndCardActionsDoNotEnterClipboard() {
        let steps: [ReplySegment] = [.text("Start"), .steps(0..<1), .text("```choices\nProceed?\n- Yes\n- No\n```\n# Finish")]
        let projection = TranscriptText(reply: "", segments: steps)
        #expect(projection.string == "Start\n\nProceed?\n\nFinish")
        #expect(projection.parts.count == 3 && projection.parts[1].isEmpty)
        #expect(TranscriptText(user: "```choices\n- Yes\n- No\n```").string == "- Yes\n- No")
    }

    @MainActor @Test func selectAllIncludesUnlaidHistoryAndResetsOnSwitch() {
        let owner = UUID(), id = UUID(), selection = TranscriptSelection()
        var value = "Streaming"
        selection.show(owner, rows: [id]) { _ in value }
        let older = ArchivedMessage(id: "older", seq: 0, role: "user", text: "Earlier", hidden: false, channel: "chat")
        selection.showHistory(owner, rows: [older])
        selection.selectAll()
        value += " later"
        #expect(selection.copiedText == "Earlier\n\nStreaming")
        selection.show(UUID(), rows: [id]) { _ in "Other conversation" }
        #expect(!selection.hasText && selection.copiedText.isEmpty)
    }
}
