import Darwin
import Foundation

extension AppStore {
    @discardableResult func restoreSetAsideStore() -> Bool {
        guard let offer = storeRestoreOffer else { return false }
        let staged = fileURL.appendingPathExtension("restoring-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let data = try Data(contentsOf: offer.url)
            let file = try StoreFile.decode(data)
            try data.write(to: staged, options: .withoutOverwriting)
            // Another launch may have saved while the prompt was open. Publish atomically only to a vacant path.
            guard renamex_np(staged.path, fileURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            resolveStoreRecovery()
            adoptRestoredStore(file)
            migrateSampleBots()
            selectVisibleChat()
            storeRestoreNote = StoreRestoreCopy.restored(offer.botCount)
            errorMessage = nil
            save()
            return true
        } catch {
            resolveStoreRecovery()
            resumeSavingAfterRecovery()
            storeRestoreNote = StoreRestoreCopy.failed
            return false
        }
    }

    func resolveStoreRecovery() {
        storeRestoreOffer = nil
        let latest = StoreRestore.candidates(for: fileURL).first.map(StoreRestore.date) ?? .distantPast
        defaults.set(max(Date(), latest), forKey: StoreRestore.decisionKey(for: fileURL))
    }

    func recordHealthyStoreIfNeeded() {
        let key = StoreRestore.decisionKey(for: fileURL)
        let resolved = defaults.object(forKey: key) as? Date ?? .distantPast
        if resolved < .now { defaults.set(Date(), forKey: key) }
    }

    func declineStoreRestore() {
        guard storeRestoreOffer != nil else { return }
        resolveStoreRecovery()
        resumeSavingAfterRecovery()
    }
}
