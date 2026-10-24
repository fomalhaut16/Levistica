import AppKit
import Testing
import WebKit
@testable import Levistica

@MainActor
struct LocalPDFTests {
    private func fixture(encrypted: Bool = false) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("synthetic.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = encrypted ? [kCGPDFContextUserPassword: "synthetic", kCGPDFContextOwnerPassword: "synthetic-owner"] as CFDictionary : nil
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    @Test func onlyTheSelectedFileAndItsFragmentAreAllowed() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = try LocalPDF(selectedURL: url)
        #expect(document.allows(url))
        #expect(document.allows(URL(string: url.absoluteString + "#page=2")))
        #expect(!document.allows(url.deletingLastPathComponent().appendingPathComponent("other.pdf")))
        #expect(!document.allows(URL(string: "https://example.com/")))
        #expect(!document.allows(URL(string: url.absoluteString + "?another=file")))
        #expect(!NavigationPolicy.allows(url, isMainFrame: true))
    }

    @Test func malformedOrMissingFilesDoNotChangeTheCurrentTab() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = BrowserSession(dataStore: .nonPersistent())
        let selected = session.selectedID
        try Data("<html>This is not a PDF</html>".utf8).write(to: url)
        #expect(throws: LocalPDF.Failure.invalid) { try session.openLocalPDF(selectedURL: url) }
        #expect(session.selectedID == selected && session.tabs.count == 1 && session.loadedPageCount == 0)
        #expect(throws: (any Error).self) { _ = try LocalPDF(selectedURL: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        #expect(throws: (any Error).self) { try session.openLocalPDF(selectedURL: url) }
    }

    @Test func openedDocumentPathNeverEntersTheSessionSnapshot() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let database = url.deletingLastPathComponent().appendingPathComponent("session.sqlite3")
        let store = try SessionStore(fileURL: database)
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        try session.openLocalPDF(selectedURL: url)
        #expect(session.prepareToQuit())
        let saved = try #require(try store.load())
        #expect(saved.tabs.count == 1)
        #expect(saved.tabs[0].kind == .localPDF && saved.tabs[0].url == nil && !saved.tabs[0].mayReload)
        #expect(saved.tabs[0].title == "ローカルPDF")
        #expect(try Data(contentsOf: database).range(of: Data(url.path.utf8)) == nil)
    }

    @Test func openingPDFAtCapacityKeepsTheSelectedTabAndSavedSession() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SessionStore(fileURL: url.deletingLastPathComponent().appendingPathComponent("session.sqlite3"))
        let records = (0..<1000).map { SavedTab(id: UUID(), title: "Synthetic tab \($0)", url: nil, mayReload: true) }
        let selected = records[50].id
        try store.save(SavedSession(tabs: records, selectedID: selected, wasRunning: false))
        let session = BrowserSession(dataStore: .nonPersistent(), store: store)
        session.activeTab.addressDraft = "unsent synthetic address"
        try session.openLocalPDF(selectedURL: url)
        #expect(session.tabs.map(\.id) == records.map(\.id))
        #expect(session.selectedID == selected)
        #expect(session.activeTab.addressDraft == "unsent synthetic address")
        #expect(session.loadedPageCount == 0)
        #expect(session.externalOpenNotice != nil)
        #expect(session.prepareToQuit())
        #expect(try store.load()?.tabs.count == 1000)
    }

    @Test func encryptedPDFIsRejectedExplicitly() throws {
        let url = try fixture(encrypted: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: LocalPDF.Failure.encrypted) { _ = try LocalPDF(selectedURL: url) }
    }

    @Test func closingReleasesTheDocumentAndReopenRequiresSelection() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = BrowserSession(dataStore: .nonPersistent())
        weak var document: LocalPDF?
        try session.openLocalPDF(selectedURL: url)
        #expect(session.tabs.count == 1)
        #expect(session.page?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false)
        autoreleasepool {
            document = session.page?.localPDF
            session.closeTab(session.selectedID)
        }
        #expect(document == nil)
        session.reopenClosedTab()
        #expect(session.activeTab.isLocalPDF)
        #expect(session.page == nil && session.activeTab.pendingURL == nil)
        #expect(session.activeTab.addressDraft.isEmpty)
        #expect(session.activeTab.restorationNotice != nil)
    }

    @Test func navigatingFromLocalPDFReleasesItsDocumentAndRuntime() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let session = BrowserSession(dataStore: .nonPersistent())
        weak var document: LocalPDF?
        weak var runtime: PageRuntime?
        weak var view: WKWebView?
        try autoreleasepool {
            try session.openLocalPDF(selectedURL: url)
            let original = try #require(session.page)
            let tabID = session.selectedID
            let originalDocument: LocalPDF = try #require(original.localPDF)
            document = originalDocument
            runtime = original
            view = original.webView
            #expect(session.navigate("http://127.0.0.1:54321/after-local-pdf"))
            #expect(session.selectedID == tabID)
            #expect(session.tabs.count == 1 && session.loadedPageCount == 1)
            #expect(session.activeTab.isLocalPDF == false)
            #expect(session.page?.localPDF == nil)
            #expect(session.page !== original)
            #expect(session.page?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == true)
        }
        #expect(document == nil)
        #expect(runtime == nil)
        #expect(view == nil)
        session.closeTab(session.selectedID)
    }
}
