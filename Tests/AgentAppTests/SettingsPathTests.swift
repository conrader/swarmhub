import Foundation
import Testing
@testable import AgentApp

// P32 8: the copy that sends people to Settings names the pane that exists, and the buttons open it.
@Test func settingsPathsNameTheRealPane() {
    #expect(SettingsLayout.path(.servers) == "Settings → Advanced → Servers and keys")
    #expect(SettingsLayout.path(.servers, "Add bots from box") == "Settings → Advanced → Servers and keys → Add bots from box")
    #expect(SettingsLayout.home(of: "servers.addFromBox") == .advanced(.servers), "Add bots from box lives on that pane")
    #expect(SetupCopy.addLater.contains(SettingsLayout.path(.servers)))
    #expect(OpenClawEditorCopy.noGateway.contains(SettingsLayout.path(.servers, "OpenClaw")))
}

