import SwiftUI

/// The routine editor's Advanced part (P21b item 2): the raw schedule text Hermes stores. Typing a line the picker can
/// show moves the picker to it; anything else stays exactly as typed.
struct RoutineScheduleAdvanced: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Cron (0 9 * * 1) or interval (every 30m)", text: $text).font(.system(.body, design: .monospaced))
            Text("Cron fields: minute hour day month weekday, in the server's time zone. Hermes also takes \"every 30m\", a duration or an ISO time.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
