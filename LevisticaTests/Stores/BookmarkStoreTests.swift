import Foundation
import SQLite3
import Testing
@testable import Levistica

@MainActor struct BookmarkStoreTests {
    private func version(_ file: URL) throws -> Int32 {
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(database) }
        var row: OpaquePointer?
        try #require(sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &row, nil) == SQLITE_OK)
        defer { sqlite3_finalize(row) }
        try #require(sqlite3_step(row) == SQLITE_ROW)
        return sqlite3_column_int(row, 0)
    }

    @Test(arguments: ["👩‍💻 開発", "می\u{200C}خواهم"])
    func joiningNamesPromoteOnlyWhenWrittenAndSurviveReopen(_ title: String) throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        let url = try #require(URL(string: "https://example.com/"))
        let id = try store.add(url: url, title: "Plain")
        #expect(try version(file) == 2)
        // A duplicate keeps its existing name and must not promote its format.
        #expect(try store.add(url: url, title: title) == id)
        #expect(try version(file) == 2)
        try store.rename(id, title: title)
        #expect(try version(file) == 3)
        #expect(try BookmarkStore(fileURL: file).load().first?.title == title)
        try store.remove(id)
        #expect(try version(file) == 3) // Removing data must not silently downgrade it.
    }

    @Test func joiningFolderNamesPromoteAndSurviveReopen() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        _ = try store.add(url: #require(URL(string: "https://example.com/")), title: "Plain", folders: ["👨‍👩‍👧‍👦", "می\u{200C}خواهم"])
        #expect(try version(file) == 3)
        #expect(try BookmarkStore(fileURL: file).load().first?.folders == ["👨‍👩‍👧‍👦", "می\u{200C}خواهم"])
    }

    @Test func failedImportRollsBackBothJoinedTextAndFormatPromotion() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        _ = try store.add(url: #require(URL(string: "https://example.com/keep")), title: "Keep")
        let before = try store.load()
        let joined = ImportedBookmark(url: try #require(URL(string: "https://example.com/new")), title: "👩‍💻", folders: [])
        let invalid = ImportedBookmark(url: try #require(URL(string: "javascript:alert(1)")), title: "Invalid", folders: [])
        #expect(throws: BookmarkStore.Failure.self) { try store.importEntries([joined, invalid]) }
        #expect(try version(file) == 2)
        #expect(try store.load() == before)
        #expect(try store.importEntries([joined]) == 1)
        #expect(try version(file) == 3)
        #expect(try BookmarkStore(fileURL: file).load().contains(where: { $0.title == "👩‍💻" }))
    }

    @Test func ordinaryBookmarkActionsKeepNamesAndRejectOtherControls() throws {
        let library = BookmarkLibrary()
        library.add(url: try #require(URL(string: "https://example.com/")), title: "👩‍💻 開発")
        #expect(library.notice == nil && library.items.first?.title == "👩‍💻 開発")
        library.renameSelected("می\u{200C}خواهم")
        #expect(library.notice == nil && library.items.first?.title == "می\u{200C}خواهم")
        for control in ["\n", "\u{0000}", "\u{200B}", "\u{202E}", "\u{2066}"] {
            #expect(!BookmarkStore.validTitle("before" + control + "after"))
            #expect(!BookmarkStore.validFolders(["before" + control + "after"]))
        }
    }

    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("bookmarks.sqlite3")
    }

    @Test func addRenameDuplicateAndReopenPreserveTheCustomName() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        let url = try #require(URL(string: "https://example.com/research"))
        let id = try store.add(url: url, title: "Original")
        try store.rename(id, title: "My research")
        #expect(try store.add(url: url, title: "Site changed its title") == id)
        #expect(try BookmarkStore(fileURL: file).load() == [Bookmark(id: id, url: url, title: "My research")])
    }

    @Test func separateConnectionsDoNotOverwriteUnrelatedChanges() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = try BookmarkStore(fileURL: file)
        let second = try BookmarkStore(fileURL: file)
        let a = try first.add(url: #require(URL(string: "https://example.com/a")), title: "A")
        let b = try second.add(url: #require(URL(string: "https://example.com/b")), title: "B")
        try first.rename(a, title: "Renamed A")
        #expect(try second.load().count == 2)
        try second.remove(a)
        #expect(try first.load().map(\.id) == [b])
    }

    @Test func unsafeURLsAndInvalidTitlesNeverReplaceSavedItems() throws {
        let store = try BookmarkStore(fileURL: nil)
        let url = try #require(URL(string: "https://example.com/safe"))
        let id = try store.add(url: url, title: "Safe")
        for raw in ["file:///tmp/private.pdf", "javascript:alert(1)", "https://example.com/?access_token=synthetic", "https://user:pass@example.com/"] {
            let bad = try #require(URL(string: raw))
            #expect(throws: (any Error).self) { try store.add(url: bad, title: "Rejected") }
        }
        #expect(throws: (any Error).self) { try store.rename(id, title: String(repeating: "a", count: 513)) }
        #expect(throws: (any Error).self) { try store.rename(id, title: "\n") }
        #expect(try store.load() == [Bookmark(id: id, url: url, title: "Safe")])
    }

    @Test func unreadableAndFutureDataRemainUntouched() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let broken = Data("not a SQLite database".utf8)
        try broken.write(to: file)
        #expect(throws: (any Error).self) { try BookmarkStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == broken)
        try FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let future = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try BookmarkStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == future)
    }

    @Test func capDoesNotPreventSelectingAnExistingBookmark() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        let sql = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<1000) INSERT INTO bookmarks (id,url,title,created) SELECT printf('00000000-0000-0000-0000-%012d',x),'https://example.com/'||x,'Synthetic',x FROM n"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        _ = try store.add(url: #require(URL(string: "https://example.com/1")), title: "Duplicate")
        #expect(throws: (any Error).self) { try store.add(url: #require(URL(string: "https://example.com/new")), title: "New") }
        #expect(try store.load().count == 1000)
    }

    @Test func libraryIsLazyAndRemovalCanBeUndone() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let session = BrowserSession(bookmarkFileURL: file)
        #expect(!session.bookmarks.isLoaded && !FileManager.default.fileExists(atPath: file.path))
        session.showBookmarks()
        #expect(session.loadedPageCount == 0 && session.bookmarks.isLoaded)
        session.bookmarks.add(url: try #require(URL(string: "https://example.com/")), title: "Example")
        let original = session.bookmarks.items
        session.bookmarks.removeSelected()
        #expect(session.bookmarks.items.isEmpty)
        session.bookmarks.undoRemoval()
        #expect(session.bookmarks.items == original)
        #expect(session.loadedPageCount == 0)
    }
}
