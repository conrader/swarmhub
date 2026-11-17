import Foundation

extension AppStore {
    var visibleChatCount: Int { sidebarChats.count }

    /// Match sidebar order, skip hidden conversations, and wrap at either end.
    func moveChatSelection(by offset: Int) {
        let chats = sidebarChats
        let count = chats.count
        guard count > 0 else { return }
        let current = chats.firstIndex { $0.id == (selectedGroup?.id ?? selectedBot?.id) }
        open(chats[current.map { (($0 + offset) % count + count) % count } ?? (offset < 0 ? count - 1 : 0)])
    }
}

extension AppStore {
    /// Dictation has its key, so the composer shows the microphone. Without one the button would only lead to an
    /// error, so it is not shown; Settings → Voice says how to set it up.
    var dictationIsSetUp: Bool {
        if let known = dictationKeyKnown { return known }
        let saved = keyStore.hasKey(for: DeAPICredentials.account)
        dictationKeyKnown = saved
        return saved
    }

    /// Settings saved or removed the key.
    func dictationKeyChanged() { dictationKeyKnown = keyStore.hasKey(for: DeAPICredentials.account); objectWillChange.send() }
}
