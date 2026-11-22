import SwiftUI

/// What a program in beta cannot do yet, under the control that chooses it. The sentence is the server's
/// (`HerdrClient.Template.note`); the app adds no words of its own. Nothing shows for a program without one.
struct HerdrProgramNote: View {
    let note: String?

    var body: some View {
        if let note, !note.isEmpty {
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
