import Foundation
import Testing
@testable import AgentApp

// P44 3: `[SILENT]` routine results and delivered messages. Synthetic jobs on FakeJobsServer only.

@Test func onlyTheWholeMarkerInAnyCaseIsSilent() {
    #expect(SilentReply.isSilent("[SILENT]") && SilentReply.isSilent("  [silent]\n") && SilentReply.isSilent("[Silent]"))
    #expect(!SilentReply.isSilent("[SILENT] but the disk is full") && !SilentReply.isSilent("SILENT") && !SilentReply.isSilent(""))
    #expect(!ChatMessage(role: .user, content: "[SILENT]").isSilent, "the user's own text is never hidden")
}

