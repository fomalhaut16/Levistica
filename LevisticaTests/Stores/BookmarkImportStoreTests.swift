import Foundation
import SQLite3
import Testing
@testable import Levistica

struct BookmarkImportStoreTests {
    private func database(_ file: URL, _ sql: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw BookmarkStore.Failure.unavailable }
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        var row: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &row, nil) == SQLITE_OK)
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        return Int(sqlite3_column_int(row, 0))
    }
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("bookmarks.sqlite3")
    }

    @Test func legacyMigrationPreservesRecordsAndRetainsAnIndependentOldFormatCopy() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = UUID()
        _ = try database(file,"CREATE TABLE bookmarks(id TEXT PRIMARY KEY,url TEXT UNIQUE,title TEXT,created REAL); INSERT INTO bookmarks VALUES('\(id.uuidString)','https://example.com/','Existing',1); PRAGMA user_version=1;")
        let store = try BookmarkStore(fileURL: file)
        #expect(try store.load() == [Bookmark(id: id, url: URL(string: "https://example.com/")!, title: "Existing")])
        #expect(try database(file, "") == 2)
        let copies = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("bookmarks-v1-") }
        #expect(copies.count == 1)
        let copy = try #require(copies.first)
        #expect(try database(copy, "") == 1)
        try store.rename(id, title: "Renamed")
        #expect(try database(copy, "") == 1)
        var read: OpaquePointer?
        #expect(sqlite3_open_v2(copy.path, &read, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(read) }
        var row: OpaquePointer?
        #expect(sqlite3_prepare_v2(read, "SELECT title FROM bookmarks", -1, &row, nil) == SQLITE_OK)
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        let title = try #require(sqlite3_column_text(row, 0))
        #expect(String(cString: title) == "Existing")
    }

    @Test func malformedLegacyDataIsNotMigratedOrBackedUp() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = try database(file,"CREATE TABLE bookmarks(id TEXT PRIMARY KEY,url TEXT UNIQUE,title TEXT,created REAL); INSERT INTO bookmarks VALUES('bad-id','javascript:bad','Bad',1); PRAGMA user_version=1;")
        let bytes = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try BookmarkStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path).count == 1)
    }

    @Test func batchPreservesExistingNamesAndDifferentFoldersAndSurvivesReopening() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        let url = try #require(URL(string: "https://example.com/"))
        let id = try store.add(url: url, title: "Custom name")
        let entries = [ImportedBookmark(url: url, title: "Imported", folders: []),
                       ImportedBookmark(url: url, title: "Research", folders: ["Research"])]
        #expect(try store.importEntries(entries) == 1)
        #expect(try store.importEntries(entries) == 0)
        let items = try BookmarkStore(fileURL: file).load()
        #expect(items.count == 2)
        #expect(items.first(where: { $0.id == id })?.title == "Custom name")
        #expect(items.first(where: { $0.folders == ["Research"] })?.title == "Research")
    }

    @MainActor @Test func undoingRemovalPreservesTheImportedFolderAndIdentity() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        _ = try store.importEntries([ImportedBookmark(url: URL(string: "https://example.com/")!, title: "Research", folders: ["A", "B"])])
        let library = BookmarkLibrary(fileURL: file)
        library.load()
        let original = library.items
        library.selectedID = try #require(original.first).id
        library.removeSelected()
        #expect(library.items.isEmpty)
        library.undoRemoval()
        #expect(library.items == original)
    }

    @Test func invalidBatchAndCapacityFailureRollbackEveryNewEntry() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        let good = ImportedBookmark(url: URL(string: "https://example.com/new")!, title: "New", folders: [])
        let bad = ImportedBookmark(url: URL(string: "javascript:bad")!, title: "Bad", folders: [])
        #expect(throws: (any Error).self) { try store.importEntries([good, bad]) }
        #expect(try store.load().isEmpty)
        _ = try database(file,"WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<999) INSERT INTO bookmarks(id,url,title,created) SELECT printf('00000000-0000-0000-0000-%012d',x),'https://example.com/'||x,'Synthetic',x FROM n")
        let extra = ImportedBookmark(url: URL(string: "https://example.org/extra")!, title: "Extra", folders: [])
        #expect(throws: (any Error).self) { try store.importEntries([good, extra]) }
        #expect(try store.load().count == 999)
        #expect(try store.load().contains { $0.url == good.url } == false)
    }
}
