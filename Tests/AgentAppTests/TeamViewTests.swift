import AppKit
import Foundation
import Testing
@testable import AgentApp

@MainActor struct TeamViewTests {
    @Test func syntheticCoordinationScreensRender() async throws {
        guard ProcessInfo.processInfo.environment["SWARMHUB_RENDER_TESTS"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "SwarmHub-Team-Preview")
        #expect(await HeadlessSetup.render(to: directory, only: "team", output: { _ in }) == 0)
        for name in ["team-uncertain", "team-project-context"] {
            let data = try Data(contentsOf: directory.appending(path: name + ".png"))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide > 0 && data.count > 4_000)
        }
    }
}
