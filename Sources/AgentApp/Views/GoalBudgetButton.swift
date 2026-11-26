import SwiftUI

/// Edits the command in the composer. The person can review it before sending.
struct GoalBudgetButton: View {
    @Binding var draft: String
    let focusComposer: () -> Void
    @State private var showing = false
    @State private var amount = ""
    @State private var perGoal = true

    var body: some View {
        if let command = SlashCommand.editableGoal(in: draft) {
            Button("Budget…") {
                guard case .start(_, _, let existing, let goal) = command else { return }
                amount = existing.map { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
                perGoal = existing == nil || goal
                showing = true
            }.popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Spending limit").font(.headline)
                    Picker("Count spending from", selection: $perGoal) {
                        Text("This goal’s steps").tag(true)
                        Text("Entire session").tag(false)
                    }
                    TextField("Amount in USD", text: $amount)
                    Text("OpenCode checks its estimate before each step. A running step can exceed the limit.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { showing = false }
                        Button("Apply") {
                            guard let updated = command.settingBudget(amount, perGoal: perGoal) else { return }
                            draft = updated
                            showing = false
                            focusComposer()
                        }.disabled(command.settingBudget(amount, perGoal: perGoal) == nil)
                    }
                }.padding(14).frame(width: 285)
            }
        }
    }
}
