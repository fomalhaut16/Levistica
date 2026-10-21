import Foundation
import SQLite3
import Testing
@testable import Levistica

@MainActor struct HistoryStoreTests {
    private func file() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.sqlite3")
    }

    @Test func revisitUpdatesOneURLAndSearchSurvivesReopen() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        let a = try #require(URL(string: "https://example.com/a"))
        let b = try #require(URL(string: "https://example.com/b"))
        let now = Date()
        try await store.record(url: a, title: "First", now: now.addingTimeInterval(-2))
        try await store.record(url: b, title: "資料B", now: now.addingTimeInterval(-1))
        try await store.record(url: a, title: "Latest", now: now)
        let reopened = HistoryStore(fileURL: file)
        #expect(try await reopened.search().map(\.url) == [a, b])
        #expect(try await reopened.search("LATEST").map(\.title) == ["Latest"])
        #expect(try await reopened.search("資料").map(\.url) == [b])
        try await reopened.remove(a)
        #expect(try await store.search().map(\.url) == [b])
    }

    @Test func delayedTitlesCannotRecreateDeletedVisitsOrOverwriteALaterVisit() async throws {
        let store = HistoryStore(fileURL: nil)
        let url = try #require(URL(string: "https://example.com/"))
        let first = Date().addingTimeInterval(-10)
        let later = Date()
        try await store.record(url: url, title: "Loading", now: first)
        try await store.updateTitle(url: url, title: "Finished", visited: first)
        #expect(try await store.search().first?.title == "Finished")
        try await store.clear()
        try await store.updateTitle(url: url, title: "Late title", visited: first)
        #expect(try await store.search().isEmpty)
        try await store.record(url: url, title: "New visit", now: later)
        try await store.updateTitle(url: url, title: "Old document title", visited: first)
        #expect(try await store.search().first?.title == "New visit")
    }

    @Test func secretsAreRejectedAndSiteTitlesAreBounded() async throws {
        let store = HistoryStore(fileURL: nil)
        for raw in ["file:///tmp/private.pdf", "https://example.com/?token=synthetic", "https://user:pass@example.com/", "javascript:alert(1)"] {
            try await store.record(url: #require(URL(string: raw)), title: "Not saved")
        }
        #expect(try await store.search().isEmpty)
        try await store.record(url: #require(URL(string: "https://example.com/")), title: "\n" + String(repeating: "a", count: 1000))
        let item = try #require(try await store.search().first)
        #expect(item.title.utf16.count <= 512 && !item.title.contains("\n"))
    }

    @Test func expiryAndCapacityAreSeparateFromTheDisplayLimit() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        let now = Date()
        try await store.record(url: #require(URL(string: "https://example.com/expired")), title: "Expired", now: now.addingTimeInterval(-91 * 86400))
        try await store.record(url: #require(URL(string: "https://example.com/seed")), title: "Seed", now: now)
        #expect(try await store.search("expired", now: now).isEmpty)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<9999) INSERT INTO history SELECT 'https://example.com/'||x,CASE WHEN x=1 THEN 'Older searchable page' ELSE 'Synthetic' END,\(now.timeIntervalSince1970)-10000+x FROM n"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        try await store.record(url: #require(URL(string: "https://example.com/new")), title: "Newest", now: now.addingTimeInterval(1))
        #expect(try await store.search().count == 200)
        #expect(try await store.search("Older searchable page").isEmpty) // The oldest was evicted at the cap.
        #expect(try await store.search("/2").isEmpty == false) // Search covers records outside the latest 200.
        var row: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM history", -1, &row, nil) == SQLITE_OK)
        defer { sqlite3_finalize(row) }
        #expect(sqlite3_step(row) == SQLITE_ROW)
        #expect(sqlite3_column_int(row, 0) == 10_000)
    }

    @Test func lockedWriteKeepsThePreviousHistory() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        let old = try #require(URL(string: "https://example.com/old"))
        try await store.record(url: old, title: "Keep me")
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: (any Error).self) {
            try await store.record(url: #require(URL(string: "https://example.com/new")), title: "Blocked")
        }
        #expect(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        #expect(try await store.search().map(\.url) == [old])
    }

    @Test func corruptAndFutureFilesAreNotOverwritten() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let broken = Data("not a database".utf8)
        try broken.write(to: file)
        let corrupt = HistoryStore(fileURL: file)
        await #expect(throws: (any Error).self) { try await corrupt.clear() }
        #expect(try Data(contentsOf: file) == broken)
        try FileManager.default.removeItem(at: file)
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let bytes = try Data(contentsOf: file)
        let future = HistoryStore(fileURL: file)
        await #expect(throws: (any Error).self) { try await future.clear() }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func queuedVisitsCannotReappearAfterClearAndBookmarksRemain() async throws {
        let session = BrowserSession()
        let url = try #require(URL(string: "https://example.com/"))
        session.bookmarks.add(url: url, title: "Keep this bookmark")
        session.history.record(url: url, title: "Queued visit")
        session.history.clear()
        session.showHistory()
        await session.history.flush()
        #expect(session.history.items.isEmpty && !session.history.isBusy)
        #expect(session.bookmarks.items.count == 1 && session.loadedPageCount == 0)
        session.history.record(url: url, title: "A later visit is a new record")
        await session.history.flush()
        #expect(session.history.items.count == 1)
    }
}
