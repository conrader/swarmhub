import AppKit
import SwiftUI

/// Copies a command or an address to the pasteboard.
struct CopyButton: View {
    let text: String
    var body: some View {
        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy")
    }
}
