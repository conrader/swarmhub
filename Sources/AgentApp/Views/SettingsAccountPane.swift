import SwiftUI

/// Settings → Servers: the servers your bots run on, each with its connection, helpers, skills and projects, and the
/// Grok Bot import where Grok Bot is on this Mac.
struct SettingsAccountPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppleMetrics.groupSpacing) {
            HerdrSettingsSection()
            SettingsGrokSection()
        }
    }
}
