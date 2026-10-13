import Foundation
import SwiftUI

/// `THIRD-PARTY-NOTICES.md`: the installed app's Contents/Resources (copied by `package-release.sh`), or the checkout
/// when run from the package root, as `AvatarAssets` finds its PNGs.
enum ThirdPartyNotices {
    static let fileName = "THIRD-PARTY-NOTICES.md"
    static let credit = "Bot avatars: BotAvatarsKit by Jakub Antalik (Libraries.dev), MIT licence."

    static func text(bundleResources: URL? = Bundle.main.resourceURL, checkout: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [bundleResources?.appending(path: fileName), executable.appending(path: "../../\(fileName)").standardizedFileURL, checkout.appending(path: fileName)].compactMap { $0 }
        return candidates.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
    }
}

/// Settings → Updates → Acknowledgements: the credit line and, on demand, the licence text from the bundle.
struct AcknowledgementsSection: View {
    @State private var expanded = false
    private let notices = ThirdPartyNotices.text()

    var body: some View {
        Section("Acknowledgements") {
            Text(ThirdPartyNotices.credit)
            if let notices {
                DisclosureGroup("Licence", isExpanded: $expanded) {
                    ScrollView { Text(notices).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220)
                }
            } else {
                Text("\(ThirdPartyNotices.fileName) was not found in this build.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
