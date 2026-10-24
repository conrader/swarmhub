import Foundation

/// autoctx1: the restore prompt's two answers. Restore copies the set-aside file over store.json (whatever store.json
/// held is moved aside as `store.json.before-restore-<stamp>`, never deleted) and loads it in this window; Start fresh
/// keeps the set-aside file untouched and seeds the default bot only where a fresh launch would have.
extension AppStore {
    @discardableResult func restoreSetAsideStore() -> Bool {
        guard let offer = storeRestoreOffer else { return false }
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let staged = directory.appending(path: "store.json.restoring-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: staged) }
        do {
            let file = try StoreFile.decode(Data(contentsOf: offer.url))
            // The copy is made first; store.json is only moved aside once it exists, and put back if the swap fails.
            try manager.copyItem(at: offer.url, to: staged)
            var setAside: URL?
            if manager.fileExists(atPath: fileURL.path) {
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                let aside = directory.appending(path: "store.json.before-restore-\(stamp)")
                try manager.moveItem(at: fileURL, to: aside); setAside = aside
            }
            do { try manager.moveItem(at: staged, to: fileURL) }
            catch { if let setAside { try? manager.moveItem(at: setAside, to: fileURL) }; throw error }
            storeRestoreOffer = nil
            adoptRestoredStore(file)
            migrateManagerRole(); migrateSampleBots()
            selectVisibleChat()
            storeRestoreNote = StoreRestoreCopy.restored(offer.botCount)
            save()
            if botInfo.autoLoad, hermesConfigured, launchProbesGlobalHermes { Task { await refreshHermesAgents() } }
            return true
        } catch {
            storeRestoreOffer = nil
            storeRestoreNote = StoreRestoreCopy.failed
            return false
        }
    }

    var declinedRestores: Set<String> { Set(defaults.stringArray(forKey: StoreRestore.declinedKey) ?? []) }

    /// The set-aside file stays where it is; it is not offered again. A window whose store.json was unreadable saves again
    /// (store.json is new; the unreadable copy and every backup are left as they are) and starts as a fresh launch would.
    func declineStoreRestore() {
        guard let offer = storeRestoreOffer else { return }
        storeRestoreOffer = nil
        defaults.set(Array(declinedRestores.union([offer.url.lastPathComponent])).sorted(), forKey: StoreRestore.declinedKey)
        resumeSavingAfterSetAside()
        if bots.isEmpty, persistenceEnabled, hermesConfigured, !FileManager.default.fileExists(atPath: fileURL.path) {
            seedDefaultHermesBot(); selectVisibleChat()
        }
    }
}
