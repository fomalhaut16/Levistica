import Foundation
import Observation

@MainActor @Observable
final class BookmarkLibrary {
    private(set) var items: [Bookmark] = []
    private(set) var isLoaded = false
    var selectedID: UUID?
    var notice: String?
    private(set) var recentlyDeleted: Bookmark?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var store: BookmarkStore?

    init(fileURL: URL? = nil) { self.fileURL = fileURL }
    var isPersistent: Bool { fileURL != nil }

    func load() {
        do {
            let source = try store ?? BookmarkStore(fileURL: fileURL)
            let loaded = try source.load()
            store = source
            items = loaded
            isLoaded = true
            notice = nil
        } catch { notice = error.localizedDescription; isLoaded = false }
    }

    func add(url: URL, title: String) {
        mutate { store in
            let bounded = String(decoding: title.utf16.prefix(512), as: UTF16.self)
                .components(separatedBy: .controlCharacters).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            selectedID = try store.add(url: url, title: bounded.isEmpty ? (url.host ?? "ブックマーク") : bounded)
        }
    }

    func renameSelected(_ title: String) {
        guard let selectedID else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BookmarkStore.validTitle(value) else {
            notice = "名前を短くし、空欄や改行を避けて入力してください。"
            return
        }
        mutate { try $0.rename(selectedID, title: value) }
    }

    func removeSelected() {
        guard let item = items.first(where: { $0.id == selectedID }) else { return }
        mutate { store in
            try store.remove(item.id)
            recentlyDeleted = item
            selectedID = nil
        }
    }

    func undoRemoval() {
        guard let item = recentlyDeleted else { return }
        mutate { store in
            selectedID = try store.add(url: item.url, title: item.title, id: item.id)
            recentlyDeleted = nil
        }
    }

    private func mutate(_ action: (BookmarkStore) throws -> Void) {
        if !isLoaded { load() }
        guard isLoaded, let store else { return }
        do {
            try action(store)
            items = try store.load()
            notice = nil
        } catch { notice = error.localizedDescription }
    }
}
