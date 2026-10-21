import Foundation
import Observation

@MainActor @Observable
final class HistoryLibrary {
    private(set) var items: [HistoryEntry] = []
    private(set) var isBusy = false
    private(set) var preferences = HistoryPreferences()
    private(set) var preferencesLoaded = false
    var isVisible = false
    var selectedID: String?
    var query = ""
    var notice: String?
    let isPersistent: Bool
    @ObservationIgnored private let store: HistoryStore
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(fileURL: URL? = nil) {
        store = HistoryStore(fileURL: fileURL)
        isPersistent = fileURL != nil
    }

    func record(url: URL, title: String, visited: Date = Date()) {
        guard SessionStore.persistableURL(url) == url else { return }
        enqueue { try await $0.record(url: url, title: title, now: visited) }
    }
    func updateTitle(url: URL, title: String, visited: Date) {
        enqueue { try await $0.updateTitle(url: url, title: title, visited: visited) }
    }
    func load() { enqueue { _ in } }
    func setPreferences(_ value: HistoryPreferences) {
        enqueue { try await $0.setPreferences(value) }
    }
    func removeSelected() {
        guard let item = items.first(where: { $0.id == selectedID }) else { return }
        enqueue { try await $0.remove(item.url) }
    }
    func clear() { enqueue { try await $0.clear() } }
    func flush() async { await pending?.value }

    private func enqueue(_ action: @escaping @Sendable (HistoryStore) async throws -> Void) {
        generation += 1
        let current = generation
        let previous = pending
        isBusy = true
        pending = Task { [weak self, store] in
            await previous?.value
            guard let self else { return }
            do {
                try await action(store)
                preferences = try await store.preferences()
                preferencesLoaded = true
                if isVisible { items = try await store.search(query) }
                notice = nil
            } catch { notice = error.localizedDescription }
            if generation == current { isBusy = false; pending = nil }
        }
    }
}
