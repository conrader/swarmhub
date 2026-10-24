import Foundation

/// autoctx1: the restore prompt's two answers. Restore copies the set-aside file over store.json (whatever store.json
/// held is moved aside as `store.json.before-restore-<stamp>`, never deleted) and loads it in this window; Start fresh
/// keeps the set-aside file untouched and seeds the default bot only where a fresh launch would have.
extension AppStore {
    @discardableResult func restoreSetAsideStore() -> Bool {
        guard let offer = storeRestoreOffer else { return false }
        let manager = FileManager.default
        do {
            let file = try StoreFile.decode(Data(contentsOf: offer.url))
            if manager.fileExists(atPath: fileURL.path) {
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                try manager.moveItem(at: fileURL, to: fileURL.deletingLastPathComponent().appending(path: "store.json.before-restore-\(stamp)"))
            }
            try manager.copyItem(at: offer.url, to: fileURL)
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

    func declineStoreRestore() {
        guard storeRestoreOffer != nil else { return }
        storeRestoreOffer = nil
        if bots.isEmpty, persistenceEnabled, hermesConfigured, !FileManager.default.fileExists(atPath: fileURL.path) {
            seedDefaultHermesBot(); selectVisibleChat()
        }
    }
}
