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

    @Test func embeddedNullAndUnicodeTitleSurvivePrimaryAndBackupRoundTrips() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Before\0After \u{1F30C} e\u{301}",
                           url: URL(string: "https://example.com/"), mayReload: true)
        let saved = SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false)
        try store.save(saved)
        #expect(try store.load() == saved)
        try store.writeCleanBackup()
        #expect(try SessionStore.readCleanBackup(of: url) == saved)
    }

    @Test(arguments: [
        "UPDATE session_tabs SET id=id||char(0)||'suffix'",
        "UPDATE session_meta SET selected_id=selected_id||char(0)||'suffix'",
        "UPDATE session_tabs SET kind=kind||char(0)||'suffix'",
        "UPDATE session_tabs SET title=CAST(X'80' AS TEXT)",
        "UPDATE session_tabs SET title=X'41'"
    ])
    func malformedStoredTextIsRejected(_ sql: String) throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Original", url: nil, mayReload: false)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { _ = try store.load() }
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

    @Test(arguments: ["is_kept=4294967296", "is_sleeping=-1", "is_kept='text'", "is_sleeping=1.5",
                      "may_reload=4294967296", "may_reload=4294967297", "may_reload='text'", "may_reload=0.5",
                      "position=4294967296", "position=-4294967296", "position='text'", "position=0.5"])
    func invalidTabIntegerFieldsAreRejected(_ update: String) throws {
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

    @Test(arguments: ["4294967296", "4294967297", "'text'", "0.5"])
    func invalidRunningFlagIsRejected(_ value: String) throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Before", url: nil, mayReload: false)
        try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "UPDATE session_meta SET was_running=" + value, nil, nil, nil) == SQLITE_OK)
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

    @MainActor @Test(arguments: [1, 2])
    func invalidLegacyRecordsDoNotCommitAnUpgrade(_ version: Int) throws {
        let (url, saved) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let backup = try Data(contentsOf: url.appendingPathExtension("backup"))
        try FileManager.default.removeItem(at: url)
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let id = UUID().uuidString
        let kindColumn = version == 2 ? ", kind TEXT NOT NULL DEFAULT 'web'" : ""
        let kindValue = version == 2 ? ", 'web'" : ""
        let sql = """
        CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL,
            title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL\(kindColumn));
        CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL);
        INSERT INTO session_tabs VALUES ('\(id)',0,'Legacy tab','https://example.com/',2\(kindValue));
        INSERT INTO session_meta VALUES (1,'\(id)',0);
        PRAGMA user_version=\(version);
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try #require(result == SQLITE_OK)
        let before = try Data(contentsOf: url)
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        session.activateInitialSelection()
        #expect(session.storageFailure != nil)
        #expect(session.loadedPageCount == 0)
        #expect(session.canRestoreSessionBackup)
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
        #expect(session.restoreSessionBackup())
        session.activateInitialSelection()
        #expect(session.recoveryRequired)
        #expect(session.loadedPageCount == 0)
        #expect(session.tabs.map(\.id) == saved.tabs.map(\.id))
        #expect(session.selectedID == saved.selectedID)
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
    }

    @Test func failedMultiStepMigrationPreservesLegacyDatabase() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        let id = UUID().uuidString
        // A conflicting later column permits the v1 -> v2 step, then rejects v3.
        let sql = """
        CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL,
            title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL, is_kept INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL);
        INSERT INTO session_tabs (id, position, title, url, may_reload) VALUES ('\(id)',0,'Legacy tab','https://example.com/',1);
        INSERT INTO session_meta VALUES (1,'\(id)',0);
        PRAGMA user_version=1;
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        sqlite3_close(database)
        try #require(result == SQLITE_OK)
        let before = try Data(contentsOf: url)
        #expect(throws: (any Error).self) { _ = try SessionStore(fileURL: url) }
        #expect(try Data(contentsOf: url) == before)
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


    private func recoveryFixture() throws -> (URL, SavedSession) {
        let url = try temporaryURL()
        let store = try SessionStore(fileURL: url)
        let first = SavedTab(id: UUID(), title: "Recovered document", url: URL(string: "https://example.com/one"), mayReload: true)
        let second = SavedTab(id: UUID(), title: "Kept sleeping", url: URL(string: "https://example.com/two"),
                              mayReload: true, isKept: true, isSleeping: true)
        let saved = SavedSession(tabs: [first, second], selectedID: first.id, wasRunning: false)
        try store.save(saved)
        try store.writeCleanBackup()
        return (url, saved)
    }

    @MainActor @Test func corruptSessionRecoveryPreservesOriginalSidecarsAndWaitsToLoad() throws {
        let (url, saved) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data("unreadable original".utf8)
        try original.write(to: url, options: .atomic)
        let backup = try Data(contentsOf: url.appendingPathExtension("backup"))
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        try #require(session.canRestoreSessionBackup)
        for suffix in ["-wal", "-shm", "-journal"] {
            try Data("preserve sidecar".utf8).write(to: URL(fileURLWithPath: url.path + suffix))
        }
        #expect(session.recoveryBackupTabCount == 2)
        #expect(session.recoveryBackupDate != nil)
        #expect(session.restoreSessionBackup())
        #expect(session.tabs.map(\.id) == saved.tabs.map(\.id))
        #expect(session.selectedID == saved.selectedID)
        #expect(session.tabs[1].isKept && session.tabs[1].isSleeping)
        session.activateInitialSelection()
        #expect(session.loadedPageCount == 0)
        #expect(session.recoveryRequired)
        #expect(session.canRestoreSessionBackup == false)
        #expect(session.storageFailure == nil)
        #expect(try Data(contentsOf: url) == original)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
        for suffix in ["-wal", "-shm", "-journal"] {
            #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) == Data("preserve sidecar".utf8))
        }
        let current = try SessionStore.currentFileURL(in: folder)
        #expect(current != url)
        #expect(try SessionStore(fileURL: current).load()?.wasRunning == true)
        #expect(try SessionStore.readCleanBackup(of: current) == saved)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("current-session.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restarted = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(restarted.tabs.map(\.id) == saved.tabs.map(\.id))
        #expect(restarted.recoveryRequired)
        #expect(restarted.loadedPageCount == 0)
    }

    @MainActor @Test(arguments: [false, true])
    func missingOrEmptyPrimaryOffersBackupWithoutReplacingOriginal(_ empty: Bool) throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        if empty { try Data().write(to: url, options: .atomic) }
        else { try FileManager.default.removeItem(at: url) }
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(session.canRestoreSessionBackup)
        #expect(session.restoreSessionBackup())
        if empty { #expect(try Data(contentsOf: url).isEmpty) }
        else { #expect(FileManager.default.fileExists(atPath: url.path) == false) }
    }

    @MainActor @Test(arguments: ["UPDATE session_tabs SET may_reload=2",
                                "UPDATE session_tabs SET may_reload=4294967297",
                                "UPDATE session_tabs SET position=position+4294967296",
                                "UPDATE session_meta SET was_running=4294967296",
                                "DELETE FROM session_tabs; DELETE FROM session_meta"])
    func invalidOrEmptyTabDataDoesNotReplaceBackup(_ sql: String) throws {
        let (url, saved) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        let backup = try Data(contentsOf: url.appendingPathExtension("backup"))
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        session.activateInitialSelection()
        #expect(session.loadedPageCount == 0)
        #expect(session.storageFailure != nil)
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
        #expect(session.canRestoreSessionBackup)
        #expect(session.restoreSessionBackup())
        session.activateInitialSelection()
        #expect(session.recoveryRequired)
        #expect(session.loadedPageCount == 0)
        #expect(session.tabs.map(\.id) == saved.tabs.map(\.id))
        #expect(session.selectedID == saved.selectedID)
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
    }

    @MainActor @Test func newerOriginalAndCorruptBackupAreNeverRestored() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        try #require(sqlite3_exec(database, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        let newer = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(newer.canRestoreSessionBackup == false)
        #expect(newer.restoreSessionBackup() == false)
        #expect(try Data(contentsOf: url) == before)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("current-session.json").path) == false)
        let bad = Data("corrupt".utf8)
        try bad.write(to: url, options: .atomic)
        try bad.write(to: url.appendingPathExtension("backup"), options: .atomic)
        let noBackup = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(noBackup.canRestoreSessionBackup == false)
        #expect(noBackup.restoreSessionBackup() == false)
        #expect(try Data(contentsOf: url) == bad)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == bad)
    }

    @MainActor @Test func recoveryCannotDiscardNewDraftOrTabs() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = Data("unreadable".utf8)
        try original.write(to: url, options: .atomic)
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        try #require(session.canRestoreSessionBackup)
        session.activeTab.addressDraft = "unsent synthetic search"
        #expect(session.canRestoreSessionBackup == false)
        #expect(session.restoreSessionBackup() == false)
        #expect(session.activeTab.addressDraft == "unsent synthetic search")
        session.activeTab.addressDraft = ""
        _ = session.newTab()
        #expect(session.restoreSessionBackup() == false)
        #expect(session.tabs.count == 2)
        #expect(try Data(contentsOf: url) == original)
    }

    @MainActor @Test(arguments: ["../outside.sqlite3", "session.sqlite3", "/tmp/outside.sqlite3", "recovered-session-invalid.sqlite3"])
    func unsafeLocationCannotOverwriteDefaultSession(_ name: String) throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: url)
        let pointer = folder.appendingPathComponent("current-session.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "fileName": name])
        try data.write(to: pointer)
        #expect(throws: (any Error).self) { _ = try SessionStore.currentFileURL(in: folder) }
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(session.storageFailure != nil)
        #expect(session.prepareToQuit())
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: pointer) == data)
    }

    @MainActor @Test func missingPointerCannotSilentlySelectAnOlderSession() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: url)
        let recovered = folder.appendingPathComponent("recovered-session-" + UUID().uuidString + ".sqlite3")
        try Data("preserve recovered copy".utf8).write(to: recovered)
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(session.storageFailure != nil)
        #expect(session.canRestoreSessionBackup == false)
        #expect(session.prepareToQuit())
        #expect(try Data(contentsOf: url) == before)
        #expect(try Data(contentsOf: recovered) == Data("preserve recovered copy".utf8))
    }

    @Test func snapshotReadIsPrivateAndHandlesSpecialPathCharacters() throws {
        let base = try temporaryURL().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("saved # with spaces?").appendingPathComponent("session.sqlite3")
        let store = try SessionStore(fileURL: url)
        let tab = SavedTab(id: UUID(), title: "Private", url: URL(string: "https://example.com/"), mayReload: true)
        let saved = SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false)
        try store.save(saved)
        try store.writeCleanBackup()
        let before = try Data(contentsOf: store.backupURL)
        #expect(try SessionStore.readCleanBackup(of: url) == saved)
        #expect(try Data(contentsOf: store.backupURL) == before)
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: store.backupURL.path + "-shm") == false)
    }

    @Test func locationRejectsDanglingPointerAndLinkedTarget() throws {
        let url = try temporaryURL()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let manager = FileManager.default
        let pointer = folder.appendingPathComponent("current-session.json")
        try manager.createSymbolicLink(at: pointer, withDestinationURL: folder.appendingPathComponent("missing.json"))
        #expect(throws: (any Error).self) { _ = try SessionStore.currentFileURL(in: folder) }
        try manager.removeItem(at: pointer)
        let name = "recovered-session-" + UUID().uuidString + ".sqlite3"
        try Data("target".utf8).write(to: url)
        try manager.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: url)
        try JSONSerialization.data(withJSONObject: ["version": 1, "fileName": name]).write(to: pointer)
        #expect(throws: (any Error).self) { _ = try SessionStore.currentFileURL(in: folder) }
    }


    @MainActor @Test func futureLocationFormatDoesNotRewriteAnySession() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: url)
        let pointer = folder.appendingPathComponent("current-session.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "fileName": "recovered-session-" + UUID().uuidString + ".sqlite3"])
        try data.write(to: pointer)
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        #expect(session.canRestoreSessionBackup == false)
        #expect(session.storageFailure?.contains("新しい形式") == true)
        #expect(session.prepareToQuit())
        #expect(try Data(contentsOf: pointer) == data)
        #expect(try Data(contentsOf: url) == before)
    }

    @MainActor @Test(arguments: [1, 2])
    func recoveryRejectsChangedLocationWithoutCreatingCandidates(_ version: Int) throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: folder) }
        let damaged = Data("unreadable original".utf8)
        try damaged.write(to: url, options: .atomic)
        let backup = try Data(contentsOf: url.appendingPathExtension("backup"))
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        try #require(session.canRestoreSessionBackup)
        let other = folder.appendingPathComponent("recovered-session-" + UUID().uuidString + ".sqlite3")
        do {
            let store = try SessionStore(fileURL: other)
            let tab = SavedTab(id: UUID(), title: "New current session", url: nil, mayReload: false)
            try store.save(SavedSession(tabs: [tab], selectedID: tab.id, wasRunning: false))
        }
        let otherBefore = try Data(contentsOf: other)
        let pointer = folder.appendingPathComponent("current-session.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": version, "fileName": other.lastPathComponent])
        try data.write(to: pointer)
        let names = Set(try manager.contentsOfDirectory(atPath: folder.path))
        #expect(session.restoreSessionBackup() == false)
        #expect(try Data(contentsOf: pointer) == data)
        #expect(try Data(contentsOf: url) == damaged)
        #expect(try Data(contentsOf: other) == otherBefore)
        #expect(try Data(contentsOf: url.appendingPathExtension("backup")) == backup)
        #expect(Set(try manager.contentsOfDirectory(atPath: folder.path)) == names)
    }

    @MainActor @Test func failedLocationPublicationRemovesOnlyItsCandidateAndCanRetry() throws {
        let (url, saved) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: folder) }
        let current: URL
        do {
            let recovered = try SessionStore.recoverCleanBackup(of: url)
            current = recovered.dataFileURL
        }
        let damaged = Data("unreadable recovered session".utf8)
        try damaged.write(to: current, options: .atomic)
        let backup = try Data(contentsOf: current.appendingPathExtension("backup"))
        let pointer = folder.appendingPathComponent("current-session.json")
        let pointerBefore = try Data(contentsOf: pointer)
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        try #require(session.canRestoreSessionBackup)
        // Block only the final location replacement; the parent remains writable.
        try manager.setAttributes([.immutable: true], ofItemAtPath: pointer.path)
        defer { try? manager.setAttributes([.immutable: false], ofItemAtPath: pointer.path) }
        let names = Set(try manager.contentsOfDirectory(atPath: folder.path))
        #expect(session.restoreSessionBackup() == false)
        #expect(try Data(contentsOf: pointer) == pointerBefore)
        #expect(try Data(contentsOf: current) == damaged)
        #expect(try Data(contentsOf: current.appendingPathExtension("backup")) == backup)
        #expect(Set(try manager.contentsOfDirectory(atPath: folder.path)) == names)
        try manager.setAttributes([.immutable: false], ofItemAtPath: pointer.path)
        #expect(session.restoreSessionBackup())
        let restarted = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        restarted.activateInitialSelection()
        #expect(restarted.recoveryRequired)
        #expect(restarted.loadedPageCount == 0)
        #expect(restarted.tabs.map(\.id) == saved.tabs.map(\.id))
        #expect(restarted.selectedID == saved.selectedID)
        #expect(try Data(contentsOf: current) == damaged)
        #expect(try Data(contentsOf: current.appendingPathExtension("backup")) == backup)
    }

    @Test func recoveryCleanupKeepsPossiblyPublishedOrUnverifiableCandidates() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        defer { try? manager.removeItem(at: folder) }
        #expect(SessionStore.canRemoveFailedRecoveryCandidate(of: url))
        let pointer = folder.appendingPathComponent("current-session.json")
        let candidate = folder.appendingPathComponent("recovered-session-" + UUID().uuidString + ".sqlite3")
        let marker = Data("preserve this possibly published candidate".utf8)
        try marker.write(to: candidate)
        for version in [1, 2] {
            let data = try JSONSerialization.data(withJSONObject: ["version": version, "fileName": candidate.lastPathComponent])
            try data.write(to: pointer)
            #expect(SessionStore.canRemoveFailedRecoveryCandidate(of: url) == false)
            #expect(try Data(contentsOf: pointer) == data)
        }
        try Data("unreadable location".utf8).write(to: pointer)
        #expect(SessionStore.canRemoveFailedRecoveryCandidate(of: url) == false)
        try manager.removeItem(at: pointer)
        try manager.createSymbolicLink(at: pointer, withDestinationURL: folder.appendingPathComponent("missing.json"))
        #expect(SessionStore.canRemoveFailedRecoveryCandidate(of: url) == false)
        #expect(try Data(contentsOf: candidate) == marker)
    }

    @MainActor @Test func healthySessionDoesNotOfferOrRunBackupRecovery() throws {
        let (url, _) = try recoveryFixture()
        let folder = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = BrowserSession.persistentSession(in: folder, dataStore: .nonPersistent())
        let before = try Data(contentsOf: url)
        #expect(session.storageFailure == nil)
        #expect(session.canRestoreSessionBackup == false)
        #expect(session.restoreSessionBackup() == false)
        #expect(try Data(contentsOf: url) == before)
        #expect(try SessionStore.currentFileURL(in: folder) == url)
    }

}
