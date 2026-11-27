import SwiftUI

struct HelperSteeringComposer: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject var draft: HelperSteeringDraft
    let chatID: UUID
    let jump: JumpToLatestButton
    @FocusState private var focused: Bool
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "arrow.turn.down.right")
                Text("Steering " + draft.target.name).fontWeight(.semibold)
                Text(verbatim: draft.target.task).lineLimit(1).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                jump
                Button {
                    store.helperSteeringDrafts.removeValue(forKey: chatID)
                    store.composerFocus = chatID
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Cancel helper guidance")
            }.font(.caption).help(draft.target.reference)
            HStack {
                TextField("Instruction for " + draft.target.name, text: $draft.text)
                    .textFieldStyle(.plain).focused($focused).onSubmit(submit)
                Button(action: submit) { Image(systemName: "arrow.up") }
                    .buttonStyle(ComposerRoundButtonStyle(prominent: true))
                    .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send helper guidance")
            }
            if rejected { Text("Could not send this instruction to the selected session.").font(.caption).foregroundStyle(.secondary) }
        }.padding(12).background(AppColor.card, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: 768)
            .onAppear { focused = true }
            .task(id: store.composerFocus) {
                guard store.composerFocus == chatID else { return }
                focused = true
                store.composerFocus = nil
            }
    }

    private func submit() { rejected = !store.submitHelperSteering(in: chatID) }
}
