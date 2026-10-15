import Foundation

/// Profile names are unique only within their connection.
struct BoxProfileSelection: Equatable {
    let target: String
    let name: String
}

extension AppStore {
    static let deletedBoxProfilesKey = "sidebar.deletedBoxProfiles"

    private var deletedBoxProfiles: [String: [String]] {
        get { defaults.dictionary(forKey: Self.deletedBoxProfilesKey) as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.deletedBoxProfilesKey) }
    }

    func isDeletedBoxProfile(_ name: String, on target: String) -> Bool {
        deletedBoxProfiles[target]?.contains(name) == true
    }

    var selectedDisconnectedProfile: BoxProfile? {
        guard let selection = selectedBoxProfile else { return nil }
        return boxProfiles[selection.target]?.first { $0.name == selection.name }
    }

    var sidebarBoxProfiles: [BoxProfileSelection] {
        boxProfiles.keys.sorted().flatMap { target in
            (boxProfiles[target] ?? []).map { BoxProfileSelection(target: target, name: $0.name) }
        }
    }

    func open(_ selection: BoxProfileSelection) {
        if let profile = boxProfiles[selection.target]?.first(where: { $0.name == selection.name }) { open(profile, on: selection.target) }
    }

    func open(_ profile: BoxProfile, on target: String) {
        guard boxProfiles[target]?.contains(where: { $0.name == profile.name }) == true else { return }
        selectedBot = nil; selectedGroup = nil; openThreadID = nil; replyTo = nil
        selectedBoxProfile = BoxProfileSelection(target: target, name: profile.name)
    }

    /// Like deleting a connected bot, this removes its local entry. Discovery must not bring it back at launch.
    func deleteBoxProfile(_ profile: BoxProfile, on target: String) {
        guard let current = boxProfiles[target]?.first(where: { $0.name == profile.name }), current.state != .adopting else { return }
        var deleted = deletedBoxProfiles
        if !(deleted[target] ?? []).contains(profile.name) { deleted[target, default: []].append(profile.name) }
        deletedBoxProfiles = deleted
        let remaining = (boxProfiles[target] ?? []).filter { $0.name != profile.name }
        boxProfiles[target] = remaining.isEmpty ? nil : remaining
        if selectedBoxProfile == BoxProfileSelection(target: target, name: profile.name) { selectVisibleChat() }
    }

    /// An explicit Add all is also the way to bring a locally deleted profile back.
    func restoreDeletedBoxProfiles(on target: String) {
        var deleted = deletedBoxProfiles; deleted[target] = nil; deletedBoxProfiles = deleted
    }
}
