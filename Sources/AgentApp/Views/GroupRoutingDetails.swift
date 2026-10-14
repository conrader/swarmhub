import SwiftUI

/// The group panel's Advanced part (P21b item 3): how a group message is routed, read from `GroupRouting`, and where
/// each member runs. Words only; routing itself is unchanged.
struct GroupRoutingDetails: View {
    let members: [Bot]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            detail("Who answers", "Without an @mention a message goes to every member, one after another, in the order listed above.")
            detail("@mentions", "Type @ and a member's name to send only to them; several names reach each of them in member order. Unknown names and e-mail addresses are ignored.")
            detail("Context", "Each member gets the group's messages since its last reply, up to \(GroupRouting.contextLimit.formatted()) characters (oldest dropped first); attached documents are sent whole.")
            detail("Sessions", "Each member keeps its own session for this group.")
            if !members.isEmpty {
                Text("Where each member runs").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(members) { bot in
                    Text("\(bot.name) · \(Self.place(bot))").font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    static func place(_ bot: Bot) -> String {
        bot.backend == .hermes ? "Hermes · \(bot.hermesProfile ?? "default")" : bot.backend.rawValue
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
