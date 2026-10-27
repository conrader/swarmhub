import SwiftUI

/// uxfix1: transient network trouble left over after the retries, as one small line at the bottom of the window (never the
/// modal alert). It clears itself when the box answers again or the network comes back; Dismiss clears it now.
struct ConnectionNoticeBar: View {
    let text: String; let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Connection interrupted. SwarmHub keeps retrying.").fontWeight(.medium)
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", action: dismiss).buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss connection notice")
        }.font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial)
            .accessibilityIdentifier("connection.notice")
    }
}
