import Testing
import WebKit
@testable import Levistica

@MainActor
struct BrowserSessionTests {
    @Test func relatedPageCallbacksDoNotRetainAClosedRuntime() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let openerID = session.selectedID
        weak var runtime: PageRuntime?
        weak var view: WKWebView?
        try autoreleasepool {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let child = try #require(session.openRelatedPage(configuration: configuration, openerID: openerID,
                                                             origin: "https://example.com", foreground: true))
            runtime = child
            view = child.webView
            child.webViewDidClose(child.webView)
        }
        #expect(session.tabs.count == 1)
        #expect(runtime == nil)
        #expect(view == nil)
    }

    @Test func relatedPagePreservesDataStoreAndCanCloseBackToItsOpener() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let openerID = session.selectedID
        let configuration = WKWebViewConfiguration()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = dataStore
        configuration.preferences.minimumFontSize = 17
        let child = try #require(session.openRelatedPage(configuration: configuration, openerID: openerID,
                                                        origin: "https://example.com", foreground: true))
        #expect(child.webView.configuration.websiteDataStore === dataStore)
        #expect(child.webView.configuration.preferences.minimumFontSize == 17)
        #expect(child.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically == false)
        #expect(session.tabs.count == 2)
        #expect(session.activeTab.openerID == openerID)
        #expect(session.activeTab.openerOrigin == "https://example.com")
        child.webViewDidClose(child.webView)
        #expect(session.selectedID == openerID)
        #expect(session.tabs.count == 1)
        #expect(session.openRelatedPage(configuration: configuration, openerID: UUID(),
                                         origin: "https://example.com", foreground: true) == nil)
    }

    @Test func ordinaryPageCannotCloseItsTabThroughTheScriptCloseCallback() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        #expect(session.navigate("http://127.0.0.1:54321/fixture"))
        let id = session.selectedID
        let page = try #require(session.page)
        page.webViewDidClose(page.webView)
        #expect(session.tabs.count == 1)
        #expect(session.selectedID == id)
    }
    @Test func securityDelegatesAreExposedToWebKit() {
        let page = PageRuntime(dataStore: .nonPersistent())
        #expect(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        #expect(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        #expect(page.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
    }

    @Test func invalidInputDoesNotAllocateWebView() {
        let session = BrowserSession()
        #expect(session.page == nil)
        #expect(session.navigate("javascript:alert(1)") == false)
        #expect(session.page == nil)
        #expect(session.inputError != nil)
    }

    @Test func runtimeCanBeReleasedWithItsWebView() {
        weak var runtime: PageRuntime?
        weak var view: WKWebView?
        autoreleasepool {
            let page = PageRuntime(dataStore: .nonPersistent())
            runtime = page
            view = page.webView
            #expect(runtime != nil)
        }
        #expect(runtime == nil)
        #expect(view == nil)
    }

    @Test func processTerminationIsReportedWithoutReplacingThePage() {
        let page = PageRuntime(dataStore: .nonPersistent())
        let view = page.webView
        page.webViewWebContentProcessDidTerminate(view)
        #expect(page.failure != nil)
        #expect(page.webView === view)
        #expect(page.isLoading == false)
    }

    @Test func oneHundredBlankTabsDoNotAllocateWebViews() {
        let session = BrowserSession(dataStore: .nonPersistent())
        for _ in 1..<100 { _ = session.newTab() }
        #expect(session.tabs.count == 100)
        #expect(session.loadedPageCount == 0)
    }

    @Test func selectionKeepsTheSameRuntimeAndWebView() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let original = session.activeTab
        let runtime = PageRuntime(dataStore: .nonPersistent())
        original.page = runtime
        _ = session.newTab()
        #expect(session.page == nil)
        session.select(original.id)
        #expect(session.page === runtime)
        #expect(session.page?.webView === runtime.webView)
        session.select(UUID())
        #expect(session.selectedID == original.id)
    }

    @Test func closingTabsReleasesRuntimeAndPreservesSelection() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let firstID = session.selectedID
        weak var runtime: PageRuntime?
        weak var view: WKWebView?
        let second = session.newTab()
        autoreleasepool {
            let page = PageRuntime(dataStore: .nonPersistent())
            runtime = page
            view = page.webView
            second.page = page
        }
        session.closeTab(second.id)
        #expect(session.selectedID == firstID)
        #expect(session.tabs.count == 1)
        #expect(runtime == nil)
        #expect(view == nil)
        #expect(second.page == nil)
    }

    @Test func closingTheLastTabLeavesAnEmptyTabAndReopenIsBounded() {
        let session = BrowserSession(dataStore: .nonPersistent())
        session.closeTab(session.selectedID)
        #expect(session.tabs.count == 1)
        #expect(session.page == nil)
        #expect(session.tabs[0].id == session.selectedID)
        for _ in 0..<25 { session.closeTab(session.selectedID) }
        for _ in 0..<20 { session.reopenClosedTab() }
        #expect(session.canReopenClosedTab == false)
        #expect(session.loadedPageCount == 0)
    }

    @Test func adjacentSelectionWrapsWithoutChangingRuntimeCount() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let firstID = session.selectedID
        let second = session.newTab()
        session.selectAdjacent(1)
        #expect(session.selectedID == firstID)
        session.selectAdjacent(-1)
        #expect(session.selectedID == second.id)
        #expect(session.loadedPageCount == 0)
    }

    @Test func errorsBelongToTheTabThatReceivedTheInput() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let first = session.activeTab
        #expect(session.navigate("javascript:alert(1)") == false)
        _ = session.newTab()
        #expect(session.inputError == nil)
        session.select(first.id)
        #expect(session.inputError != nil)
        #expect(session.loadedPageCount == 0)
    }

    @Test func zoomIsBoundedAndCanBeReset() {
        let page = PageRuntime(dataStore: .nonPersistent())
        for _ in 0..<30 { page.changeZoom(by: 1.1) }
        #expect(page.zoom == 3)
        #expect(page.webView.pageZoom == 3)
        for _ in 0..<50 { page.changeZoom(by: 1 / 1.1) }
        #expect(page.zoom == 0.5)
        #expect(page.webView.pageZoom == 0.5)
        page.resetZoom()
        #expect(page.zoom == 1)
        #expect(page.webView.pageZoom == 1)
    }

    @Test func movingTabsPreservesSelectedIdentityAndRuntime() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let first = session.activeTab
        let runtime = PageRuntime(dataStore: .nonPersistent())
        first.page = runtime
        let second = session.newTab()
        let third = session.newTab()
        session.select(first.id)
        session.moveTabs(from: IndexSet(integer: 0), to: 3)
        #expect(session.tabs.map(\.id) == [second.id, third.id, first.id])
        #expect(session.selectedID == first.id)
        #expect(session.page === runtime)
        session.moveTab(first.id, by: -1)
        #expect(session.tabs.map(\.id) == [second.id, first.id, third.id])
        session.moveTabs(from: IndexSet(integer: 99), to: 0)
        #expect(session.tabs.count == 3)
    }
}
