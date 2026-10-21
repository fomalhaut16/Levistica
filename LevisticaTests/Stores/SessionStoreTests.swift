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

    @Test func versionOneMigratesWithoutChangingExistingTabs() throws {
        let url = try temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let id = UUID()
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        let sql = "CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL); CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL); INSERT INTO session_tabs VALUES ('\(id.uuidString)',0,'Original tab','https://example.com/',1); INSERT INTO session_meta VALUES (1,'\(id.uuidString)',0); PRAGMA user_version=1;"
        #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let store = try SessionStore(fileURL: url)
        let saved = try #require(try store.load())
        #expect(saved.selectedID == id && !saved.wasRunning)
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
}
