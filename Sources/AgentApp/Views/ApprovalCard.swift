import SwiftUI

struct ApprovalCard: View {
    let request: ApprovalRequest
    let decide: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "checkmark.shield").font(.headline)
            Text(request.summary).foregroundStyle(.secondary)
            if let draft = request.draft { Text(draft).font(.system(.callout, design: .monospaced)).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
            HStack { Spacer(); Button("Deny") { decide(false) }; Button("Approve") { decide(true) }.buttonStyle(.borderedProminent) }
        }.padding(14).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.35)))
            .padding(.horizontal, 16).padding(.vertical, 5)
    }
}
