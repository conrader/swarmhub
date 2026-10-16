import Foundation

/// P48: the Connect apps sheet's search field. Typing filters the shown tiles (popular and connected) at once by name;
/// after `pause` without typing it also searches Composio's full catalog and offers those apps below. The pause is
/// injected (`wait`), so tests release it by hand instead of sleeping.
@MainActor final class ConnectAppsSearch: ObservableObject {
    @Published var text = "" { didSet { if text != oldValue { schedule() } } }
    /// The catalog's apps for `searched`; empty until that search finishes.
    @Published private(set) var found: [ComposioToolkit] = []
    @Published private(set) var loading = false
    /// The term `found` belongs to; empty while a newer term waits or loads.
    @Published private(set) var searched = ""
    let pause: Duration
    private let wait: @MainActor (Duration) async throws -> Void
    private let find: @MainActor (String) async -> [ComposioToolkit]
    private var task: Task<Void, Never>?

    init(pause: Duration = .milliseconds(350), wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         find: @escaping @MainActor (String) async -> [ComposioToolkit]) {
        self.pause = pause; self.wait = wait; self.find = find
    }
    convenience init(apps: ConnectedAppsStore) { self.init(find: { [weak apps] term in await apps?.catalogMatches(term) ?? [] }) }

    var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The tiles already shown whose name (or slug) contains the term; all of them without one.
    func local(_ tiles: [ComposioToolkit]) -> [ComposioToolkit] {
        term.isEmpty ? tiles : tiles.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.id.localizedCaseInsensitiveContains(term) }
    }
    /// The catalog's matches that are not already among `local`.
    func more(than local: [ComposioToolkit]) -> [ComposioToolkit] {
        guard !term.isEmpty, searched == term else { return [] }
        return found.filter { app in !local.contains { $0.id == app.id } }
    }
    /// "No apps match": a term, nothing local, and the catalog search for it finished with nothing new.
    func nothingMatches(local: [ComposioToolkit]) -> Bool { !term.isEmpty && !loading && searched == term && local.isEmpty && more(than: local).isEmpty }
    /// Escape.
    func clear() { text = "" }
    /// Waits for the pending catalog search (tests and renders).
    func settle() async { await task?.value }

    private func schedule() {
        task?.cancel(); found = []; searched = ""
        let term = term
        guard !term.isEmpty else { loading = false; task = nil; return }
        loading = true
        task = Task { [weak self, wait, pause] in
            // A term typed over before this task ran never waits.
            guard !Task.isCancelled else { return }
            do { try await wait(pause) } catch { return }
            guard let self, !Task.isCancelled, self.term == term else { return }
            let found = await self.find(term)
            guard !Task.isCancelled, self.term == term else { return }
            self.found = found; self.searched = term; self.loading = false
        }
    }
}

extension ConnectedAppsStore {
    /// The full catalog's apps for a search, without changing the sheet's `catalog`. Before a key exists only the
    /// popular apps are known; a failed search shows its error and finds nothing.
    func catalogMatches(_ term: String) async -> [ComposioToolkit] {
        guard hasKey else { return ComposioToolkit.popular.filter { $0.name.localizedCaseInsensitiveContains(term) || $0.id.localizedCaseInsensitiveContains(term) } }
        do { return try await client.catalog(search: term).items }
        catch { self.error = describe(error); return [] }
    }
}
