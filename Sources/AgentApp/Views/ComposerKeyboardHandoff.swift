import AppKit

/// AppKit can receive typing between a sidebar selection and the new text editor becoming first responder.
@MainActor final class ComposerKeyboardHandoff {
    private var monitor: Any?
    private var replay: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var keys: [NSEvent] = []

    func begin(in window: NSWindow?, isCurrent: @escaping @MainActor () -> Bool) {
        cancel()
        guard let window, window.isKeyWindow else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self, weak window] event in
            guard let self, let window, window.isKeyWindow, event.window === window, isCurrent(),
                  event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
                  let text = event.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !((0xF700...0xF8FF).contains($0.value)) })
            else {
                self?.cancel()
                return event
            }
            if window.firstResponder is NSTextView {
                self.deliver(in: window)
                return event
            }
            guard window.firstResponder === window else {
                self.cancel()
                return event
            }
            self.keys.append(event)
            if self.replay == nil {
                self.replay = Task { [weak self, weak window] in
                    while !Task.isCancelled {
                        guard let window, window.isKeyWindow, isCurrent() else { self?.cancel(); return }
                        if window.firstResponder is NSTextView { self?.deliver(in: window); return }
                        try? await Task.sleep(for: .milliseconds(8))
                    }
                }
            }
            return nil
        }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { self?.cancel() }
        }
    }

    private func deliver(in window: NSWindow) {
        let pending = keys
        cancel()
        for key in pending { window.sendEvent(key) }
    }

    func cancel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        replay?.cancel()
        replay = nil
        expiry?.cancel()
        expiry = nil
        keys.removeAll()
    }
}
