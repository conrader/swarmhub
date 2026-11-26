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
        #expect(SlashCommand.parse("/goal --steps 2 check  logs") == .start("check  logs", stepLimit: 2))
        #expect(SlashCommand.parse("/goal —steps 1 run a check") == .start("run a check", stepLimit: 1))
        #expect(SlashCommand.parse("/goal –steps 1 run a check") == .start("run a check", stepLimit: 1))
        #expect(SlashCommand.parse("/goal --steps-extra work") == .start("--steps-extra work"))
        for draft in ["/goal --steps=2 check", "/goal --steps", "/goal --steps 2", "/goal --steps 0 work", "/goal --steps 999999999999999999999999 work"] {
            #expect(ComposerSubmission(draft: draft, hasAttachments: false) == .notice(SlashCommand.stepLimitUsage))
        }
        #expect(SlashCommand.parse("/goal —budget 2.00 --steps 4 inspect") == .start("inspect", stepLimit: 4, budgetUSD: 2))
        for value in ["-2", "0", "NaN", "2e4", "1.555", "2 --budget 3"] {
            #expect(SlashCommand.parse("/goal --budget " + value + " inspect") == .invalidBudget)
        }
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
        #expect(ComposerSubmission(draft: "/goal ", hasAttachments: false) == .edit("/goal ", hint: "Enter an objective, or use /goal --steps 3 <objective> to limit goal turns."))
        #expect(ComposerSubmission(draft: "/goal write tests", hasAttachments: false) == .goal(.start("write tests")))
        #expect(ComposerSubmission(draft: "/goal stop", hasAttachments: false) == .goal(.stop))
        #expect(ComposerSubmission(draft: "/goal status", hasAttachments: false) == .goal(.status))
        #expect(ComposerSubmission(draft: "/goal write tests", hasAttachments: true) == .goal(.start("write tests")))
        for text in ["@someone /goal", "/goal x\ny", "/goal/tests", "meet the goal", "/var/log"] {
            #expect(ComposerSubmission(draft: text, hasAttachments: false) == .message)
        }
    }
}
