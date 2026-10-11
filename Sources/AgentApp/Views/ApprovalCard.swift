import SwiftUI

struct ApprovalCard: View {
    let request: ApprovalRequest; let decide: (Bool) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield.fill").font(.title2).foregroundStyle(.orange).frame(width: 34, height: 34).background(.orange.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text("Approval needed").font(.caption.weight(.semibold)).foregroundStyle(.orange); Text(request.title).font(.headline); Text(request.summary).font(.caption).foregroundStyle(.secondary); if let draft = request.draft { Text(draft).font(.system(.caption, design: .monospaced)).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }; HStack { Button("Decline") { decide(false) }.buttonStyle(.bordered); Button { decide(true) } label: { Text("Approve").foregroundStyle(.white).padding(.horizontal, 11).padding(.vertical, 5).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain) } }
        }.padding(14).frame(maxWidth: 520, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.orange.opacity(0.28))).shadow(color: .black.opacity(0.04), radius: 10, y: 3).padding(.horizontal, 28).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
    }
}
