import Testing
@testable import AgentApp

struct SlashCommandTests {
    @Test func slashParserPreservesChatTextAndOnlyAcceptsCompleteCommands() {
        for draft in ["please /goal work", "/go", "/goalkeeper", "/goal/file", "/tmp", " /goal work",
                      "@Ada /goal work", "/commands later", "/goal one\ntwo", "/goal status\r\n", "make this a goal"] {
            #expect(SlashCommand.parse(draft) == nil)
        }
        #expect(SlashCommand.parse("/commands ") == .commands)
        #expect(SlashCommand.parse("/goal") == .goalUsage)
        #expect(SlashCommand.parse("/goal  ship  this 📦 ") == .start("ship  this 📦"))
        #expect(SlashCommand.parse("/goal status") == .status)
        #expect(SlashCommand.parse("/goal\tstop") == .stop)
    }

    @Test func slashMenuSelectionEditsDraftBeforeReturnCanRunACommand() {
        var menu = SlashMenu()
        #expect(menu.choices(for: "/") == [.goal, .commands])
        let movedUp = menu.move(-1, draft: "/")
        #expect(movedUp)
        #expect(menu.selection(for: "/")?.insertion == "/commands ")
        let movedDown = menu.move(1, draft: "/")
        #expect(movedDown)
        #expect(menu.selection(for: "/")?.insertion == "/goal ")
        #expect(menu.choices(for: "/go") == [.goal])
        menu.dismiss("/go")
        #expect(menu.selection(for: "/go") == nil)
        menu.reset()
        #expect(menu.selection(for: "/go") == .goal)
        for draft in ["/goal", "/commands", "/goal ", "/go\n", "look /go", "@a", "/usr/bin"] {
            #expect(menu.selection(for: draft) == nil)
        }
    }

    @Test func composerRoutesNativeControlsBeforeOrdinaryDelivery() {
        #expect(ComposerSubmission(draft: "/commands", hasAttachments: true) == .edit("/", hint: nil))
        #expect(ComposerSubmission(draft: "/goal ", hasAttachments: false) == .edit("/goal ", hint: "Enter an objective after /goal."))
        #expect(ComposerSubmission(draft: "/goal write tests", hasAttachments: false) == .goal(.start("write tests")))
        #expect(ComposerSubmission(draft: "/goal stop", hasAttachments: false) == .goal(.stop))
        #expect(ComposerSubmission(draft: "/goal status", hasAttachments: false) == .goal(.status))
        #expect(ComposerSubmission(draft: "/goal write tests", hasAttachments: true) == .notice("Remove the attachments to use a goal command."))
        for text in ["@someone /goal", "/goal x\ny", "/goal/tests", "meet the goal", "/var/log"] {
            #expect(ComposerSubmission(draft: text, hasAttachments: false) == .message)
        }
    }
}
