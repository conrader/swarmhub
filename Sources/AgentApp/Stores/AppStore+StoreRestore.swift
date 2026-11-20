import CryptoKit
import Darwin
import Foundation

extension AppStore {
    @discardableResult func restoreSetAsideStore() -> Bool {
        guard let offer = storeRestoreOffer else { return false }
        guard bots.isEmpty, groups.isEmpty else {
            storeRestoreOffer = nil
            storeRestoreNote = StoreRestoreCopy.failed
            return false
        }
        let staged = fileURL.appendingPathExtension("restoring-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            let data = try StoreRestore.backupData(at: offer.url)
            guard SHA256.hash(data: data) == offer.digest else { throw CocoaError(.fileReadCorruptFile) }
            let file = try StoreRestore.snapshot(data, hideSamples: herdrConfigured)
            guard StoreRestore.entries(in: file, history: grokHistory) == offer.entries else { throw CocoaError(.fileReadCorruptFile) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let restored = try encoder.encode(file)
            try restored.write(to: staged, options: .withoutOverwriting)
            // Publish only to a vacant path, including when another writer saved during review.
            guard renamex_np(staged.path, fileURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            storeRevision = restored
            rememberRestoreUndo(restored)
            resolveStoreRecovery()
            defaults.set(true, forKey: Self.samplesMigrationKey)
            adoptRestoredStore(file)
            selectVisibleChat()
            storeRestoreNote = StoreRestoreCopy.restored(offer.entries.count)
            errorMessage = nil
            restoreLedger()
            return true
        } catch {
            let reviewed: Date? = defaults.object(forKey: StoreRestore.decisionKey(for: fileURL)) as? Date
            storeRestoreOffer = StoreRestore.offer(store: fileURL, resolvedThrough: reviewed, hideSamples: herdrConfigured)
            storeRestoreNote = StoreRestoreCopy.failed
            return false
        }
    }

    private var restoreUndoKey: String { StoreRestore.decisionKey(for: fileURL) + ".undoDigest" }

    func rememberRestoreUndo(_ data: Data) {
        restoreUndoRevision = data
        defaults.set(Data(SHA256.hash(data: data)), forKey: restoreUndoKey)
    }

    func recoverRestoreUndoIfAvailable(_ data: Data) {
        if defaults.data(forKey: restoreUndoKey) == Data(SHA256.hash(data: data)) {
            restoreUndoRevision = data
            storeRestoreNote = "Restored backup."
        }
    }

    func undoStoreRestore() {
        guard let restored = restoreUndoRevision else { return }
        do {
            guard try currentStoreRevision() == restored, storeRevision == restored, runningTurns.isEmpty else {
                throw CocoaError(.fileWriteUnknown)
            }
            // Move the adopted copy aside so Undo is recoverable as well.
            try FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("before-restore-\(UUID().uuidString)"))
            storeRevision = nil
            restoreUndoRevision = nil
            defaults.removeObject(forKey: restoreUndoKey)
            adoptRestoredStore(StoreFile(bots: [], groups: []))
            turns.nextMessages.removeAll()
            selectVisibleChat()
            resolveStoreRecovery()
            storeRestoreNote = "Restore undone. The backup is still on this Mac."
        } catch {
            storeRestoreNote = "Your chats changed after the restore. The current store has been kept."
        }
    }

    func resolveStoreRecovery() {
        storeRestoreOffer = nil
        let latest = StoreRestore.candidates(for: fileURL).first.map(StoreRestore.date) ?? .distantPast
        defaults.set(max(Date(), latest), forKey: StoreRestore.decisionKey(for: fileURL))
    }

    func declineStoreRestore() {
        guard storeRestoreOffer != nil else { return }
        resolveStoreRecovery()
        resumeSavingAfterRecovery()
    }

    var canReviewStoreBackups: Bool {
        writerLeaseAvailable && bots.isEmpty && groups.isEmpty && (try? currentStoreRevision()) == nil
            && !StoreRestore.candidates(for: fileURL).isEmpty
    }

    func reviewStoreBackups() {
        guard canReviewStoreBackups else { return }
        storeRestoreOffer = StoreRestore.offer(store: fileURL, resolvedThrough: nil, hideSamples: herdrConfigured)
        if storeRestoreOffer != nil { pauseSavingForRecovery() }
    }
}
