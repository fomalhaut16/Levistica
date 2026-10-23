import Testing
import AppKit
import WebKit
@testable import Levistica

@MainActor
struct BrowserSessionTests {
    @Test func measurementStorageDefaultsToNonPersistentWithoutAnIdentifier() throws {
        let config = try MeasurementWebsiteStorage.configuration(environment: [:], bundleIdentifier: "dev.fomalhaut16.Levistica")
        #expect(config.storeID == nil)
        #expect(config.cleanupRequest == nil)
        #expect(MeasurementWebsiteStorage.dataStore(configuration: config).isPersistent == false)
    }

    @Test(arguments: ["", "invalid", "00000000-0000-0000-0000-000000000000",
                      "123456781234123412341234567890ab", " 12345678-1234-1234-1234-1234567890ab"])
    func invalidMeasurementStoreIdentifiersAreRejected(_ value: String) {
        #expect(throws: MeasurementWebsiteStorage.Failure.self) {
            try MeasurementWebsiteStorage.configuration(environment: [MeasurementWebsiteStorage.storeKey: value],
                bundleIdentifier: "dev.fomalhaut16.Levistica.measurement")
        }
    }

    @Test(arguments: ["dev.fomalhaut16.Levistica", "dev.fomalhaut16.Levistica.debug", "dev.fomalhaut16.Levistica.profile"])
    func persistentMeasurementCannotSelectAnotherBundle(_ bundle: String) {
        #expect(throws: MeasurementWebsiteStorage.Failure.self) {
            try MeasurementWebsiteStorage.configuration(
                environment: [MeasurementWebsiteStorage.storeKey: UUID().uuidString], bundleIdentifier: bundle)
        }
    }

    @Test func cleanupRequiresAnExplicitNonzeroStoreAndRequest() throws {
        let id = UUID(), request = UUID()
        let config = try MeasurementWebsiteStorage.configuration(environment: [
            MeasurementWebsiteStorage.storeKey: id.uuidString, MeasurementWebsiteStorage.cleanupKey: request.uuidString],
            bundleIdentifier: "dev.fomalhaut16.Levistica.measurement")
        #expect(config.storeID == id && config.cleanupRequest == request)
        #expect(throws: MeasurementWebsiteStorage.Failure.self) {
            try MeasurementWebsiteStorage.configuration(environment: [MeasurementWebsiteStorage.cleanupKey: request.uuidString],
                bundleIdentifier: "dev.fomalhaut16.Levistica.measurement")
        }
        #expect(throws: MeasurementWebsiteStorage.Failure.self) {
            try MeasurementWebsiteStorage.configuration(environment: [MeasurementWebsiteStorage.storeKey: id.uuidString,
                MeasurementWebsiteStorage.cleanupKey: "invalid"], bundleIdentifier: "dev.fomalhaut16.Levistica.measurement")
        }
    }

    @Test func namedMeasurementStoreIsPersistentAndRemovableWithoutWebViews() async throws {
        MeasurementWebsiteStorage.initializeManagement()
        let id = UUID()
        var store: WKWebsiteDataStore? = autoreleasepool {
            MeasurementWebsiteStorage.dataStore(configuration: .init(storeID: id, cleanupRequest: nil))
        }
        #expect(store?.isPersistent == true)
        #expect(store?.identifier == id)
        let cookie = try #require(HTTPCookie(properties: [.domain: "measurement.invalid", .path: "/",
            .name: "measurement-fixture", .value: "synthetic", .expires: Date().addingTimeInterval(600)]))
        await store?.httpCookieStore.setCookie(cookie)
        store = nil
        try await WKWebsiteDataStore.remove(forIdentifier: id)
        let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
        #expect(identifiers.contains(id) == false)
    }

    private func preferencesFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("browser-preferences.json")
    }

    @Test func newTabPageDefaultsToBlankWithoutCreatingASettingsFile() throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = BrowserPreferences(fileURL: file)
        #expect(preferences.newTabURL == nil && preferences.canSave)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func newTabURLAndBlankChoicePersistPrivately() throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = BrowserPreferences(fileURL: file)
        #expect(preferences.saveNewTabPage("www.google.com"))
        #expect(preferences.newTabURL?.absoluteString == "https://www.google.com")
        #expect(BrowserPreferences(fileURL: file).newTabURL == preferences.newTabURL)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(preferences.saveNewTabPage(""))
        #expect(BrowserPreferences(fileURL: file).newTabURL == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
    }

    @Test(arguments: ["javascript:alert(1)", "file:///tmp/private.pdf", "https://user:password@example.com/",
                      "https://example.com/?access_token=synthetic", "https://example.com:25/", "not a URL",
                      "https://example.com/\nprivate", "https://example.com/" + String(repeating: "a", count: 4096)])
    func invalidNewTabURLPreservesTheSavedChoice(_ input: String) throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = BrowserPreferences(fileURL: file)
        #expect(preferences.saveNewTabPage("https://www.google.com/"))
        let before = try Data(contentsOf: file)
        #expect(!preferences.saveNewTabPage(input))
        #expect(preferences.newTabURL?.absoluteString == "https://www.google.com/")
        #expect(try Data(contentsOf: file) == before)
    }

    @Test(arguments: ["not JSON", "{\"version\":2}", "{\"version\":1,\"newTabURL\":\"file:///private\"}"])
    func unreadableNewTabPreferencesRemainUntouched(_ contents: String) throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let data = Data(contents.utf8)
        try data.write(to: file)
        let preferences = BrowserPreferences(fileURL: file)
        #expect(!preferences.canSave && preferences.notice != nil)
        #expect(!preferences.saveNewTabPage("https://www.google.com/"))
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func linkedNewTabPreferencesCannotModifyTheTarget() throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let target = file.deletingLastPathComponent().appendingPathComponent("original")
        let data = Data("private synthetic data".utf8)
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let preferences = BrowserPreferences(fileURL: file)
        #expect(!preferences.canSave)
        #expect(!preferences.saveNewTabPage(""))
        #expect(try Data(contentsOf: target) == data)
    }

    @Test func failedSettingsSaveKeepsTheExistingNewTabChoice() throws {
        let file = try preferencesFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let preferences = BrowserPreferences(fileURL: file)
        #expect(preferences.saveNewTabPage("https://www.google.com/"))
        let original = file.appendingPathExtension("previous")
        try FileManager.default.moveItem(at: file, to: original)
        let data = try Data(contentsOf: original)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!preferences.saveNewTabPage(""))
        #expect(preferences.newTabURL?.absoluteString == "https://www.google.com/")
        #expect(try Data(contentsOf: original) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.path).isEmpty)
    }

    @Test func inMemoryNewTabPreferencesDoNotChangeAnotherSession() {
        let first = BrowserSession(dataStore: .nonPersistent())
        #expect(first.preferences.saveNewTabPage("https://www.google.com/"))
        let second = BrowserSession(dataStore: .nonPersistent())
        #expect(second.preferences.newTabURL == nil)
        #expect(first.loadedPageCount == 0 && second.loadedPageCount == 0)
    }

    @Test func rejectedNavigationPreservesTheAddressDraftAndSuccessfulSubmissionClearsItsEditFlag() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let tab = session.activeTab
        tab.addressDraft = "synthetic unfinished address"
        tab.hasEditedAddress = true
        #expect(session.navigate("javascript:alert(1)") == false)
        #expect(tab.hasEditedAddress)
        #expect(tab.addressDraft == "synthetic unfinished address")
        #expect(session.navigate("http://127.0.0.1:54321/submitted-address"))
        #expect(tab.hasEditedAddress == false)
        session.closeTab(tab.id)
    }

    @Test func keepStatePreventsSleepAndSurvivesClosingAndReopening() {
        let session = BrowserSession(dataStore: .nonPersistent())
        let tab = session.activeTab
        session.toggleKeep(tab.id)
        #expect(tab.isKept)
        session.requestSelectedTabSleep()
        #expect(session.isRequestingSleep == false)
        #expect(tab.sleepNotice?.contains("保持") == true)
        session.closeTab(tab.id)
        session.reopenClosedTab()
        #expect(session.activeTab.isKept)
        #expect(session.activeTab.isSleeping == false)
        #expect(session.loadedPageCount == 0)
    }

    @Test func departureConfirmationDistinguishesSendingAndSameDocumentLinks() throws {
        let current = try #require(URL(string: "https://example.com/draft?q=1"))
        let fragment = try #require(URL(string: "https://example.com/draft?q=1#section"))
        let other = try #require(URL(string: "https://example.com/draft?q=2"))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .reload, current: current, destination: current))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .other, current: current, destination: current))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .other, current: current, destination: fragment))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .backForward, current: current, destination: other))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .backForward, current: current, destination: fragment))
        #expect(PageRuntime.requiresDepartureConfirmation(type: .linkActivated, current: current, destination: fragment) == false)
        #expect(PageRuntime.requiresDepartureConfirmation(type: .formSubmitted, current: current, destination: other) == false)
        #expect(PageRuntime.requiresDepartureConfirmation(type: .formResubmitted, current: current, destination: other) == false)
    }

    @Test func externalBatchOnlyLoadsItsLastPage() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let urls = (0..<50).compactMap { URL(string: "http://127.0.0.1:54321/external-\($0)") }
        session.receiveExternalURLs(urls)
        #expect(session.tabs.count == 50)
        #expect(session.loadedPageCount == 1)
        #expect(session.page?.url == urls.last)
        #expect(session.tabs.dropLast().allSatisfy { $0.page == nil && $0.pendingURL != nil })
        session.activateInitialSelection()
        #expect(session.loadedPageCount == 1)
    }

    @Test func externalURLsPreserveAddressDraftsAndRejectNativeSchemes() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let original = session.activeTab
        original.addressDraft = "unfinished address"
        session.receiveExternalURLs([try #require(URL(string: "file:///etc/passwd")),
                                     try #require(URL(string: "javascript:alert(1)"))])
        #expect(session.tabs.count == 1)
        #expect(session.loadedPageCount == 0)
        #expect(original.addressDraft == "unfinished address")
        #expect(session.externalOpenNotice != nil)
        session.receiveExternalURLs([try #require(URL(string: "http://127.0.0.1:54321/external"))])
        #expect(session.tabs.count == 2)
        #expect(original.page == nil)
        #expect(original.addressDraft == "unfinished address")
    }

    @Test func startupURLsDrainOnceBeforeRestoringTheOldSelection() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let old = session.activeTab
        let oldAddress = "http://127.0.0.1:54321/old"
        let oldURL: URL = try #require(URL(string: oldAddress))
        old.pendingURL = oldURL
        let delegate = BrowserAppDelegate()
        let incoming = try #require(URL(string: "http://127.0.0.1:54321/incoming"))
        delegate.application(.shared, open: [incoming])
        var windowRequests = 0
        delegate.connect(session: session, openWindow: { windowRequests += 1 })
        delegate.deliverPendingURLs()
        session.activateInitialSelection()
        #expect(session.tabs.count == 2)
        #expect(session.loadedPageCount == 1)
        #expect(session.page?.url == incoming)
        #expect(old.page == nil)
        delegate.connect(session: session, openWindow: { windowRequests += 1 })
        #expect(session.tabs.count == 2)
        #expect(delegate.applicationShouldHandleReopen(.shared, hasVisibleWindows: false) == false)
        #expect(windowRequests == 1)
    }

    @Test func splitNativeEventsAreDeliveredAsOneBatch() throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let delegate = BrowserAppDelegate()
        delegate.connect(session: session, openWindow: {})
        let first = try #require(URL(string: "http://127.0.0.1:54321/first"))
        let second = try #require(URL(string: "http://127.0.0.1:54321/second"))
        delegate.application(.shared, open: [first])
        delegate.application(.shared, open: [second])
        #expect(session.loadedPageCount == 0)
        delegate.deliverPendingURLs()
        #expect(session.tabs.count == 2)
        #expect(session.loadedPageCount == 1)
        #expect(session.page?.url == second)
    }

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
