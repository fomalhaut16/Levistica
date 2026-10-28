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

    @Test func backupPermissionFailureNeverStartsLegacyMigration() throws {
        let file = try file()
        let folder = file.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        _ = try database(file, "CREATE TABLE bookmarks(id TEXT PRIMARY KEY,url TEXT UNIQUE,title TEXT,created REAL); INSERT INTO bookmarks VALUES('00000000-0000-0000-0000-000000000001','https://example.com/','Original',1); PRAGMA user_version=1;")
        let original = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(throws: BookmarkStore.Failure.self) { try BookmarkStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [file.lastPathComponent])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(try database(file, "") == 1)
        let recovered = try BookmarkStore(fileURL: file)
        #expect(try recovered.load().map(\.title) == ["Original"])
        #expect(try database(file, "") == 2)
    }

    @Test func failedMigrationKeepsBothLegacyRecordsAndAnIndependentBackup() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        _ = try database(file, "CREATE TABLE bookmarks(id TEXT PRIMARY KEY,url TEXT UNIQUE,title TEXT,created REAL); INSERT INTO bookmarks VALUES('00000000-0000-0000-0000-000000000001','https://example.com/','Original',1); CREATE TABLE bookmarks_v2(sentinel TEXT); INSERT INTO bookmarks_v2 VALUES('keep'); PRAGMA user_version=1;")
        let original = try Data(contentsOf: file)
        #expect(throws: BookmarkStore.Failure.self) { try BookmarkStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try database(file, "") == 1)
        let copies = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("bookmarks-v1-") }
        let copy = try #require(copies.count == 1 ? copies.first : nil)
        #expect(try database(copy, "") == 1)
        _ = try database(file, "DROP TABLE bookmarks_v2")
        let recovered = try BookmarkStore(fileURL: file)
        #expect(try recovered.load().map(\.title) == ["Original"])
        // The backup still contains the old schema and the failed-migration sentinel.
        #expect(try database(copy, "UPDATE bookmarks_v2 SET sentinel='still present'") == 1)
    }

    @Test func databaseFailureInTheMiddleOfABatchRollsBackAndCanBeRetried() throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try BookmarkStore(fileURL: file)
        _ = try store.add(url: #require(URL(string: "https://example.com/existing")), title: "Keep")
        let before = try store.load()
        _ = try database(file, "CREATE TRIGGER synthetic_failure BEFORE INSERT ON bookmarks WHEN NEW.title='Injected failure' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END;")
        let entries = [ImportedBookmark(url: try #require(URL(string: "https://example.com/first")), title: "First", folders: ["Research"]),
                       ImportedBookmark(url: try #require(URL(string: "https://example.com/second")), title: "Injected failure", folders: ["Research"])]
        #expect(throws: BookmarkStore.Failure.self) { try store.importEntries(entries) }
        #expect(try store.load() == before)
        #expect(try BookmarkStore(fileURL: file).load() == before)
        _ = try database(file, "DROP TRIGGER synthetic_failure")
        #expect(try store.importEntries(entries) == 2)
        #expect(try store.load().count == 3)
        #expect(try store.load().first(where: { $0.id == before[0].id }) == before[0])
    }

    @MainActor @Test func confirmationRechecksEntriesAddedAfterPreviewWithoutReplacingTheirNames() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let html = file.deletingLastPathComponent().appendingPathComponent("synthetic.html")
        try Data("<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF='https://example.com/a'>Imported A</A><DT><A HREF='https://example.com/b'>Imported B</A></DL>".utf8).write(to: html)
        let library = BookmarkLibrary(fileURL: file)
        library.prepareImport(from: html)
        let deadline = ContinuousClock.now + .seconds(5)
        while library.isPreparingImport, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try #require(library.importPreview)
        try #require(library.notice == nil && library.plannedImportCount == 2)
        let writer = try BookmarkStore(fileURL: file)
        let existing = try writer.add(url: #require(URL(string: "https://example.com/a")), title: "Saved while previewing")
        library.confirmImport()
        #expect(library.notice == nil)
        #expect(library.importPreview == nil)
        #expect(library.importCompletionCount == 1)
        #expect(library.items.count == 2)
        #expect(library.items.first(where: { $0.id == existing })?.title == "Saved while previewing")
    }

}
