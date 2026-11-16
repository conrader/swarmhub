import SwiftUI

/// Settings → Advanced → Servers and keys: the Herdr servers with their access keys and helper settings, and the
/// Grok Bot import.
struct SettingsAccountPane: View {
    var body: some View {
        HerdrSettingsSection()
        SettingsGrokSection()
    }
}
