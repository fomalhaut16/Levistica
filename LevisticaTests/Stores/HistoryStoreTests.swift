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

    @Test func pausedRecordingSurvivesReopenAndKeepsExistingHistory() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        let url = try #require(URL(string: "https://example.com/kept"))
        let visited = Date()
        try await store.record(url: url, title: "Keep this title", now: visited)
        try await store.setPreferences(HistoryPreferences(recordingEnabled: false, retentionDays: 90))
        let reopened = HistoryStore(fileURL: file)
        #expect(try await reopened.preferences().recordingEnabled == false)
        try await reopened.record(url: #require(URL(string: "https://example.com/skipped")), title: "Not recorded")
        try await reopened.updateTitle(url: url, title: "Not changed", visited: visited)
        #expect(try await reopened.search().map(\.title) == ["Keep this title"])
        try await reopened.setPreferences(HistoryPreferences(recordingEnabled: true, retentionDays: 90))
        try await reopened.record(url: #require(URL(string: "https://example.com/later")), title: "Later")
        #expect(try await reopened.search().count == 2)
    }

    @Test func shorterRetentionPrunesAtomicallyAndRejectsInvalidPeriods() async throws {
        let store = HistoryStore(fileURL: nil)
        let now = Date()
        try await store.record(url: #require(URL(string: "https://example.com/old")), title: "Old", now: now.addingTimeInterval(-30 * 86400))
        try await store.record(url: #require(URL(string: "https://example.com/fresh")), title: "Fresh", now: now)
        try await store.setPreferences(HistoryPreferences(recordingEnabled: true, retentionDays: 7), now: now)
        #expect(try await store.search(now: now).map(\.title) == ["Fresh"])
        await #expect(throws: (any Error).self) {
            try await store.setPreferences(HistoryPreferences(recordingEnabled: true, retentionDays: -1))
        }
        #expect(try await store.preferences().retentionDays == 7)
        try await store.setPreferences(HistoryPreferences(recordingEnabled: true, retentionDays: 365))
        #expect(try await store.search().map(\.title) == ["Fresh"])
    }

    @Test func versionOneMigratesWithoutLosingHistoryAndInvalidRowsPreventMigration() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        func makeLegacy(title: String) throws {
            var db: OpaquePointer?
            #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            let sql = "CREATE TABLE history(url TEXT PRIMARY KEY,title TEXT,visited REAL); CREATE INDEX history_visited ON history(visited DESC); INSERT INTO history VALUES('https://example.com/','\(title)',\(Date().timeIntervalSince1970)); PRAGMA user_version=1"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        try makeLegacy(title: "Legacy visit")
        let migrated = HistoryStore(fileURL: file)
        #expect(try await migrated.preferences() == HistoryPreferences())
        #expect(try await migrated.search().map(\.title) == ["Legacy visit"])
        try FileManager.default.removeItem(at: file)
        try makeLegacy(title: "")
        let original = try Data(contentsOf: file)
        let invalid = HistoryStore(fileURL: file)
        await #expect(throws: (any Error).self) { try await invalid.preferences() }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func malformedPreferenceRowsAreRejectedWithoutChangingTheFile() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        try await store.record(url: #require(URL(string: "https://example.com/")), title: "Keep")
        for values in ["2,1,90", "1,4294967297,90", "1,1,4294967386"] {
            var db: OpaquePointer?
            #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "PRAGMA ignore_check_constraints=ON; DELETE FROM history_preferences; INSERT INTO history_preferences VALUES(\(values))", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            let original = try Data(contentsOf: file)
            let invalid = HistoryStore(fileURL: file)
            await #expect(throws: (any Error).self) { try await invalid.preferences() }
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test func failedPreferenceWritePreservesTheOldChoiceAndHistory() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        try await store.record(url: #require(URL(string: "https://example.com/old")), title: "Keep", now: Date().addingTimeInterval(-10 * 86400))
        var db: OpaquePointer?
        #expect(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        await #expect(throws: (any Error).self) {
            try await store.setPreferences(HistoryPreferences(recordingEnabled: false, retentionDays: 1))
        }
        #expect(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        #expect(try await store.preferences() == HistoryPreferences())
        #expect(try await store.search().map(\.title) == ["Keep"])
    }

    @Test func preferenceChangesFollowQueuedVisits() async throws {
        let session = BrowserSession()
        session.history.record(url: try #require(URL(string: "https://example.com/before")), title: "Before")
        session.history.setPreferences(HistoryPreferences(recordingEnabled: false, retentionDays: 90))
        session.history.record(url: try #require(URL(string: "https://example.com/after")), title: "After")
        session.showHistory()
        await session.history.flush()
        #expect(session.history.preferencesLoaded && session.history.preferences.recordingEnabled == false)
        #expect(session.history.items.map(\.title) == ["Before"])
        #expect(session.loadedPageCount == 0)
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

    @Test func unicodeSearchMatchesCaseAndCanonicalSpellingWithoutDroppingAccents() async throws {
        let store = HistoryStore(fileURL: nil)
        let url = try #require(URL(string: "https://example.com/unicode"))
        try await store.record(url: url, title: "École ΑΒΓ Café Straße")
        for query in ["éCOLE", "αβγ", "cafe\u{0301}", "STRASSE"] {
            #expect(try await store.search(query).map(\.url) == [url], "Expected Unicode match for \(query)")
        }
        #expect(try await store.search("Cafe").isEmpty)
        #expect(try await store.search("\0").isEmpty)
        #expect(try await store.search("École\0unexpected").isEmpty)
        #expect(try await store.search("%' OR 1=1--").isEmpty)
    }

    @Test func combiningCharacterQueryIsBoundedBeforeDatabaseSearch() async throws {
        let store = HistoryStore(fileURL: nil)
        let title = "a" + String(repeating: "\u{0301}", count: 511)
        let url = try #require(URL(string: "https://example.com/bounded"))
        try await store.record(url: url, title: title)
        let query = title + String(repeating: "\u{0301}", count: 100_000)
        #expect(try await store.search(query).map(\.url) == [url])
    }


    @Test func unicodeSearchIncludesOlderRecordsAfterReopeningWithoutExpandingTheDisplayLimit() async throws {
        let file = try file()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = HistoryStore(fileURL: file)
        let now = Date()
        let older = try #require(URL(string: "https://example.com/older"))
        try await store.record(url: older, title: "École ΑΒΓ", now: now.addingTimeInterval(-1000))
        var db: OpaquePointer?
        try #require(sqlite3_open(file.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<225) INSERT INTO history SELECT 'https://example.com/newer-'||x,'Synthetic',\(now.timeIntervalSince1970)-x FROM n"
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let reopened = HistoryStore(fileURL: file)
        #expect(try await reopened.search(now: now).count == 200)
        #expect(try await reopened.search(now: now).contains(where: { $0.url == older }) == false)
        #expect(try await reopened.search("école", now: now).map(\.url) == [older])
        #expect(try await reopened.search("αβγ", now: now).map(\.url) == [older])
        #expect(try await reopened.search("EXAMPLE.COM/OLDER", now: now).map(\.url) == [older])
    }

}
