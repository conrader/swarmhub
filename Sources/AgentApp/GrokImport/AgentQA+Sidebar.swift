import AppKit
import SwiftUI

extension AgentQA {
    /// Drive the sidebar's actual SwiftUI controls in the QA workspace, including when the display is locked.
    func sidebarButtons(press title: String?) async throws -> [String] {
        guard screen == "workspace" else { throw QAError("Open the workspace first.") }
        let sidebar = SidebarView(selection: .constant(store.selectedBot))
            .environmentObject(store).defaultAppStorage(store.defaults)
            .environment(\.colorScheme, scheme)
            .frame(width: 236, height: size.height)
        let host = NSHostingView(rootView: sidebar)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 236, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        var pending: [Any] = [host]
        var seen: Set<ObjectIdentifier> = []
        var buttons: [(String, NSAccessibilityProtocol)] = []
        while let object = pending.popLast() as? NSObject {
            guard seen.insert(ObjectIdentifier(object)).inserted, let node = object as? NSAccessibilityProtocol else { continue }
            if node.accessibilityRole() == .button {
                let name = node.accessibilityLabel() ?? node.accessibilityTitle() ?? ""
                if !name.isEmpty { buttons.append((name, node)) }
            }
            pending.append(contentsOf: (node.accessibilityChildren() ?? []).reversed())
        }
        if let title {
            let matches = buttons.filter { $0.0 == title }
            guard matches.count == 1, let node = matches.first?.1, node.isAccessibilityEnabled(), node.accessibilityPerformPress() else {
                throw QAError("Choose one enabled sidebar button by its exact label.")
            }
            await Task.yield()
        }
        return buttons.map(\.0)
    }
}
