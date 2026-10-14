import Foundation

/// The composer's attachments: ready ones plus files still being read (P19). Each read runs in a task whose
/// handle is kept, so removing its chip cancels it; Send waits until nothing is being read.
@MainActor final class AttachmentIntake: ObservableObject {
    struct Reading: Identifiable { let id: UUID; let label: String; let task: Task<Void, Never> }
    @Published var items: [ChatAttachment] = []
    @Published private(set) var reading: [Reading] = []
    var isReading: Bool { !reading.isEmpty }

    func attach(_ urls: [URL], store: AppStore) {
        guard !urls.isEmpty else { return }
        let id = UUID()
        let documents = urls.compactMap(DocumentKind.detect)
        let label = documents.isEmpty ? "Reading…" : documents.allSatisfy { $0 == .pdf } ? "Reading PDF…" : "Reading document…"
        let task = Task { [weak self, weak store] in
            guard let store else { return }
            let prepared = await store.prepareAttachmentsAsync(urls)
            guard let self, !Task.isCancelled, self.reading.contains(where: { $0.id == id }) else { store.discardAttachments(prepared); return }
            self.items += prepared; self.reading.removeAll { $0.id == id }
        }
        reading.append(.init(id: id, label: label, task: task))
    }

    /// The remove button on a "Reading PDF…" chip.
    func cancel(_ id: UUID) {
        guard let index = reading.firstIndex(where: { $0.id == id }) else { return }
        reading.remove(at: index).task.cancel()
    }

    /// The remove button on a ready chip: unsent page images and pasted images are deleted from `attachments/`.
    func remove(_ attachment: ChatAttachment, store: AppStore) {
        items.removeAll { $0.id == attachment.id }; store.discardAttachments([attachment])
    }
}
