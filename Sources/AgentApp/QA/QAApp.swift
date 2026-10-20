#if DEBUG
import Darwin
import Foundation
import SwiftUI

/// Select the app before SwiftUI constructs either scene graph or its stored properties.
/// SceneBuilder does not need to support runtime conditionals, and QA never initializes normal app state.
@main
@MainActor enum AgentAppLauncher {
    static func main() {
        if UIAcceptanceMode.requested { UIAcceptanceApp.main() }
        else if QAMode.enabled { QAApp.main() }
        else { AgentAppMain.main() }
    }
}

@MainActor struct QAApp: App {
    @StateObject private var controller: QAController
    @NSApplicationDelegateAdaptor(AppIconAppearance.self) private var iconAppearance

    init() {
        do {
            let controller = try QAController(directory: QAMode.activate())
            _controller = StateObject(wrappedValue: controller)
            try controller.start()
        } catch {
            // Never fall through to the user's normal launch after an invalid QA configuration.
            FileHandle.standardError.write(Data("QA launch refused: isolated local Hermes configuration required.\n".utf8))
            exit(78)
        }
    }

    var body: some Scene {
        WindowGroup("[QA-TEST] QA TEST MODE") {
            QAWorkspace(controller: controller, store: controller.store)
                .frame(minWidth: 800, minHeight: 600)
        }
    }
}
#endif
