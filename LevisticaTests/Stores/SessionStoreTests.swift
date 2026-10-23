import Foundation
import SQLite3
import Testing
import WebKit
@testable import Levistica

struct SessionStoreTests {
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("session.sqlite3")
    }

    @Test func roundTripPreservesOrderSelectionAndPrivateFilePermissions() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let first = SavedTab(id: UUID(), title: "A 'quoted' title", url: URL(string: "https://example.com/a?q=one%27two"), mayReload: true)
        let second = SavedTab(id: UUID(), title: "Blank", url: nil, mayReload: false)
        let snapshot = SavedSession(tabs: [first, second], selectedID: second.id, wasRunning: false)
        try store.save(snapshot)
        #expect(try store.load() == snapshot)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @MainActor @Test func keptAndSleepingTabsPersistWithoutCreatingPages() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Sleeping document", url: URL(string: "https://example.com/document"),
                           mayReload: true, isKept: true, isSleeping: true)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        session.activateInitialSelection()
        #expect(session.activeTab.isSleeping)
        #expect(session.activeTab.isKept)
        #expect(session.loadedPageCount == 0)
        session.toggleKeep(tab.id)
        #expect(try store.load()?.tabs.first?.isKept == false)
        #expect(try store.load()?.tabs.first?.isSleeping == true)
        #expect(session.prepareToQuit())
    }

    @Test(arguments: ["is_kept=4294967296", "is_sleeping=-1", "is_kept='text'", "is_sleeping=1.5"])
    func invalidLifecycleFlagsAreRejected(_ update: String) throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Before", url: URL(string: "https://example.com/"), mayReload: true)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "UPDATE session_tabs SET " + update, nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { _ = try store.load() }
    }

    @Test func sleepingStateRequiresAReloadableWebURL() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        for tab in [SavedTab(id: UUID(), title: "Blank", url: nil, mayReload: true, isSleeping: true),
                    SavedTab(id: UUID(), title: "POST", url: URL(string: "https://example.com/"), mayReload: false, isSleeping: true),
                    SavedTab(id: UUID(), title: "PDF", url: nil, mayReload: false, kind: .localPDF, isSleeping: true)] {
            #expect(throws: (any Error).self) { try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false)) }
        }
    }

    @Test(arguments: ["https://example.com/callback?code=secret&state=test", "https://example.com/#access_token=secret", "https://u:p@example.com/", "javascript:alert(1)", "https://example.com/?co%64e=secret"])
    func recognizableSecretsAndUnsafeSchemesAreNotPersisted(_ value: String) throws {
        #expect(SessionStore.persistableURL(URL(string: value)) == nil)
    }

    @Test func normalSearchAndDocumentAnchorsArePreserved() throws {
        let url = try #require(URL(string: "https://example.com/search?q=swift#chapter-2"))
        #expect(SessionStore.persistableURL(url) == url)
    }

    @Test func corruptedOriginalIsPreserved() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bytes = Data("not a database, preserve this original".utf8)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { _ = try SessionStore(fileURL: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func newerSchemaIsNotRewritten() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { _ = try SessionStore(fileURL: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func lockedSaveKeepsThePreviousSnapshot() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Before", url: nil, mayReload: true)
        let before = SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: true)
        try store.save(before)
        var lock: OpaquePointer?
        #expect(sqlite3_open(url.path, &lock) == SQLITE_OK)
        defer { sqlite3_close(lock) }
        #expect(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        let changed = SavedTab(id: tab.id, title: "After", url: nil, mayReload: true)
        #expect(throws: (any Error).self) {
            try store.save(SavedSession(tabs: [changed], selectedID: tab.id, wasRunning: true))
        }
        #expect(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        #expect(try store.load() == before)
    }

    @Test(arguments: [1, 2]) func olderVersionsMigrateWithoutChangingExistingTabs(_ version: Int) throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let kindColumn = version == 2 ? ", kind TEXT NOT NULL DEFAULT 'web'" : ""
        let kindValue = version == 2 ? ", 'web'" : ""
        let sql = "CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL\(kindColumn)); CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL); INSERT INTO session_tabs VALUES ('\(id.uuidString)',0,'Original tab','https://example.com/',1\(kindValue)); INSERT INTO session_meta VALUES (1,'\(id.uuidString)',0); PRAGMA user_version=\(version);"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let store = try SessionStore(fileURL: url)
        let saved = try #require(try store.load())
        #expect(saved.selectedID == id && saved.wasRunning == false)
        #expect(saved.tabs == [SavedTab(id: id, title: "Original tab", url: URL(string: "https://example.com/"), mayReload: true)])
        try store.save(saved)
        #expect(try store.load() == saved)
    }

    @MainActor @Test func localPDFRestoresOnlyASelectionPlaceholder() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "ローカルPDF", url: nil, mayReload: false, kind: .localPDF)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        session.activateInitialSelection()
        #expect(session.activeTab.isLocalPDF && session.loadedPageCount == 0)
        #expect(session.activeTab.pendingURL == nil && session.activeTab.addressDraft.isEmpty)
        #expect(session.activeTab.restorationNotice != nil)
        #expect(session.prepareToQuit())
        #expect(try store.load()?.tabs == [tab])
        let invalid = SavedTab(id: tab.id, title: "Never save this", url: URL(fileURLWithPath: "/private/synthetic.pdf"), mayReload: true, kind: .localPDF)
        #expect(throws: (any Error).self) { try store.save(SavedSession(tabs: [invalid], selectedID: tab.id, wasRunning: false)) }
        #expect(try store.load()?.tabs == [tab])
    }

    @MainActor
    @Test func oneHundredRestoredTabsStartWithoutWebViewsAndUncleanExitDefersLoading() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tabs = (0..<100).map { index in
            SavedTab(id: UUID(), title: "Document \(index)", url: URL(string: "http://127.0.0.1:54321/doc-\(index)"), mayReload: true)
        }
        try store.save(SavedSession(tabs: tabs, selectedID: tabs[42].id, wasRunning: true))
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        #expect(session.tabs.count == 100)
        #expect(session.selectedID == tabs[42].id)
        #expect(session.loadedPageCount == 0)
        #expect(session.recoveryRequired)
        session.activateInitialSelection()
        #expect(session.loadedPageCount == 0)
        session.closeTab(tabs[0].id)
        #expect(session.loadedPageCount == 0)
        #expect(session.prepareToQuit())
        #expect(try store.load()?.wasRunning == false)
    }

    @Test func cleanBackupPreservesStateAndRefreshesPrivately() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let sleeping = SavedTab(id: UUID(), title: "Sleeping", url: URL(string: "https://example.com/document"),
                                mayReload: true, isKept: true, isSleeping: true)
        let post = SavedTab(id: UUID(), title: "POST result", url: URL(string: "https://example.com/submitted"), mayReload: false)
        let saved = SavedSession(tabs: [sleeping, post], selectedID: post.id, wasRunning: false)
        try store.save(saved)
        try store.writeCleanBackup()
        #expect(try SessionStore(fileURL: store.backupURL).load() == saved)
        let changed = SavedSession(tabs: [post], selectedID: post.id, wasRunning: false)
        try store.save(changed)
        try store.writeCleanBackup()
        #expect(try SessionStore(fileURL: store.backupURL).load() == changed)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.backupURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(files.contains(where: { $0.hasPrefix(".session-backup-") }) == false)
    }

    @Test func backupIncludesCommittedWALPages() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        var connection: OpaquePointer?
        try #require(sqlite3_open(url.path, &connection) == SQLITE_OK)
        defer { sqlite3_close(connection) }
        try #require(sqlite3_exec(connection, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK)
        let tab = SavedTab(id: UUID(), title: "Committed in WAL", url: URL(string: "https://example.com/wal"), mayReload: true)
        let saved = SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false)
        try store.save(saved)
        #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
        try store.writeCleanBackup()
        #expect(try SessionStore(fileURL: store.backupURL).load() == saved)
    }

    @Test func runningOrInvalidSessionCannotReplaceGoodBackup() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Known good", url: nil, mayReload: false)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        try store.writeCleanBackup()
        let before = try Data(contentsOf: store.backupURL)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: true))
        #expect(throws: (any Error).self) { try store.writeCleanBackup() }
        #expect(try Data(contentsOf: store.backupURL) == before)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "UPDATE session_tabs SET may_reload=2", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try store.writeCleanBackup() }
        #expect(try Data(contentsOf: store.backupURL) == before)
    }

    @Test func unwritableFolderPreservesPreviousBackupAndSavedPrimary() throws {
        let url = try temporaryURL()
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Before", url: nil, mayReload: false)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        try store.writeCleanBackup()
        let before = try Data(contentsOf: store.backupURL)
        let changed = SavedTab(id: tab.id, title: "Saved after", url: nil, mayReload: false)
        let saved = SavedSession(tabs: [changed], selectedID: changed.id, wasRunning: false)
        try store.save(saved)
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) { try store.writeCleanBackup() }
        #expect(try Data(contentsOf: store.backupURL) == before)
        #expect(try store.load() == saved)
    }

    @MainActor @Test func normalExitCreatesBackupAfterSavingPrimary() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path) == false)
        session.persistSession()
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path) == false)
        #expect(session.prepareToQuit())
        #expect(session.backupFailure == nil)
        #expect(try SessionStore(fileURL: store.backupURL).load() == store.load())
        #expect(try store.load()?.wasRunning == false)
    }

    @MainActor @Test func backupFailureAllowsQuitAfterSuccessfulPrimarySave() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        try FileManager.default.createDirectory(at: store.backupURL, withIntermediateDirectories: false)
        let marker = store.backupURL.appendingPathComponent("preserve.txt")
        try Data("preserve".utf8).write(to: marker)
        #expect(session.prepareToQuit())
        #expect(session.storageFailure == nil)
        #expect(session.backupFailure != nil)
        #expect(try store.load()?.wasRunning == false)
        #expect(try Data(contentsOf: marker) == Data("preserve".utf8))
    }

    @MainActor @Test func failedPrimarySaveNeverRefreshesBackup() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        try #require(session.prepareToQuit())
        let before = try Data(contentsOf: store.backupURL)
        session.persistSession()
        var lock: OpaquePointer?
        try #require(sqlite3_open(url.path, &lock) == SQLITE_OK)
        defer { sqlite3_close(lock) }
        try #require(sqlite3_exec(lock, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
        #expect(session.prepareToQuit() == false)
        #expect(session.storageFailure != nil)
        #expect(try Data(contentsOf: store.backupURL) == before)
        try #require(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    }

}
