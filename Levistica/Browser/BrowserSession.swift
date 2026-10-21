import Observation
import WebKit
import AppKit

@MainActor
@Observable
final class BrowserSession {
    private(set) var tabs: [BrowserTab]
    private(set) var selectedID: UUID
    var addressFocusRequest = 0
    var findFocusRequest = 0
    private var dataStore: WKWebsiteDataStore?
    private let store: SessionStore?
    private var persistenceDisabled = false
    private var initialSelectionActivated = false
    private(set) var recoveryRequired = false
    private(set) var storageFailure: String?
    var externalOpenNotice: String?
    var discardUnsavedChangesOnQuit = false
    private var closedTabs: [ClosedTab] = []
    @ObservationIgnored private var inputConfirmationInProgress = false
    let downloads = DownloadManager()
    let history: HistoryLibrary
    let bookmarks: BookmarkLibrary
    var isBookmarkListVisible = false
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    @ObservationIgnored private var localPDFPanel: NSOpenPanel?

    private struct ClosedTab {
        let isLocalPDF: Bool
        let url: URL?
        let draft: String
        let mayReload: Bool
        let index: Int
    }

    init(dataStore: WKWebsiteDataStore? = nil, store: SessionStore? = nil, bookmarkFileURL: URL? = nil, historyFileURL: URL? = nil) {
        history = HistoryLibrary(fileURL: historyFileURL)
        bookmarks = BookmarkLibrary(fileURL: bookmarkFileURL)
        let tab = BrowserTab()
        tabs = [tab]
        selectedID = tab.id
        self.dataStore = dataStore
        self.store = store
        if let store {
            do {
                if let saved = try store.load() {
                    tabs = saved.tabs.map { record in
                        let restored = BrowserTab(id: record.id)
                        restored.isLocalPDF = record.kind == .localPDF
                        if restored.isLocalPDF { restored.restorationNotice = "ローカルPDFは保存していません。ファイルを選び直してください。" }
                        restored.pendingURL = record.url
                        restored.addressDraft = record.url?.absoluteString ?? ""
                        restored.storedTitle = record.title
                        restored.mayRestoreAutomatically = record.mayReload
                        if record.url != nil && !record.mayReload {
                            restored.restorationNotice = "送信後のページです。URLを確認してから開いてください。"
                        }
                        return restored
                    }
                    selectedID = saved.selectedID
                    recoveryRequired = saved.wasRunning
                }
                persistSession()
            } catch {
                persistenceDisabled = true
                storageFailure = "前回のタブ一覧を読み込めませんでした。保存データを残して起動しています。この起動では保存しません。"
            }
        }
    }

    static func applicationSession() -> BrowserSession {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let testID = environment["LEVISTICA_SESSION_TEST_ID"].flatMap(UUID.init(uuidString:))
        #else
        let testID: UUID? = nil
        #endif
        if environment["LEVISTICA_EPHEMERAL"] == "1" && testID == nil { return BrowserSession() }
        var bookmarkURL: URL?
        var historyURL: URL?
        do {
            var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                .appendingPathComponent("Levistica", isDirectory: true)
            if let testID { folder.append(path: "SessionTests/" + testID.uuidString, directoryHint: .isDirectory) }
            bookmarkURL = folder.appendingPathComponent("bookmarks.sqlite3")
            historyURL = folder.appendingPathComponent("history.sqlite3")
            return BrowserSession(store: try SessionStore(fileURL: folder.appendingPathComponent("session.sqlite3")), bookmarkFileURL: bookmarkURL, historyFileURL: historyURL)
        } catch {
            let session = BrowserSession(bookmarkFileURL: bookmarkURL, historyFileURL: historyURL)
            session.storageFailure = "タブ一覧の保存先を開けませんでした。この起動ではタブ一覧を保存しません。"
            return session
        }
    }

    var canAddBookmark: Bool {
        guard let page, !activeTab.isLocalPDF, !page.isLoading, page.failure == nil, page.canRetry else { return false }
        return SessionStore.persistableURL(page.url) != nil
    }

    func addCurrentBookmark() {
        guard canAddBookmark, let url = page?.url else { return }
        bookmarks.add(url: url, title: activeTab.displayTitle)
        history.isVisible = false
        isBookmarkListVisible = true
    }

    func showBookmarks() {
        bookmarks.load()
        history.isVisible = false
        isBookmarkListVisible = true
    }

    func showHistory() {
        isBookmarkListVisible = false
        history.isVisible = true
        history.load()
    }

    func activateInitialSelection() {
        guard !initialSelectionActivated else { return }
        initialSelectionActivated = true
        if !recoveryRequired { activatePendingTab() }
    }

    func resumeSelectedTab() {
        recoveryRequired = false
        activatePendingTab()
    }

    private func activatePendingTab() {
        let tab = activeTab
        guard let url = tab.pendingURL, tab.mayRestoreAutomatically else { return }
        _ = navigate(url.absoluteString)
    }

    private func schedulePersistence() {
        pendingSave?.cancel()
        pendingSave = Task { @concurrent [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.persistSession()
        }
    }

    func persistSession() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let store, !persistenceDisabled else { return }
        do {
            try store.save(snapshot(wasRunning: true))
            storageFailure = nil
        } catch {
            storageFailure = "タブ一覧を保存できませんでした。最後に保存できた一覧を残しています。"
        }
    }

    func prepareToQuit() -> Bool {
        if downloads.hasActive { return false }
        pendingSave?.cancel()
        pendingSave = nil
        guard let store, !persistenceDisabled, !discardUnsavedChangesOnQuit else {
            dismissPageDialogs()
            return true
        }
        do {
            try store.save(snapshot(wasRunning: false))
            storageFailure = nil
            dismissPageDialogs()
            return true
        } catch {
            storageFailure = "タブ一覧を保存できないため終了を取り消しました。再試行するか、保存せず終了を選んでください。"
            return false
        }
    }

    private func dismissPageDialogs() {
        for tab in tabs { tab.page?.dialogs.cancel() }
    }

    private func snapshot(wasRunning: Bool) -> SavedSession {
        SavedSession(tabs: tabs.map { tab in
            SavedTab(id: tab.id, title: tab.isLocalPDF ? "ローカルPDF" : tab.displayTitle,
                     url: tab.isLocalPDF ? nil : (tab.page?.url ?? tab.pendingURL),
                     mayReload: tab.isLocalPDF ? false : (tab.page?.canRetry ?? tab.mayRestoreAutomatically),
                     kind: tab.isLocalPDF ? .localPDF : .web)
        }, selectedID: selectedID, wasRunning: wasRunning)
    }

    // Selection always refers to a member; closing the last tab creates a blank one.
    var activeTab: BrowserTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var page: PageRuntime? { activeTab.page }
    var inputError: String? {
        get { activeTab.inputError }
        set { activeTab.inputError = newValue }
    }
    var canReopenClosedTab: Bool { !closedTabs.isEmpty }
    var loadedPageCount: Int { tabs.filter { $0.page != nil }.count }

    @discardableResult
    func newTab() -> BrowserTab {
        let tab = BrowserTab()
        tabs.append(tab)
        selectedID = tab.id
        addressFocusRequest += 1
        persistSession()
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        resumeSelectedTab()
        persistSession()
    }

    func selectAdjacent(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + offset % tabs.count + tabs.count) % tabs.count].id)
    }

    func receiveExternalURLs(_ urls: [URL]) {
        var last: UUID?
        var rejected = urls.count > 1000
        for url in urls.prefix(1000) {
            guard NavigationPolicy.allows(url, isMainFrame: true) else { rejected = true; continue }
            let blank = tabs.count == 1 && activeTab.page == nil && activeTab.pendingURL == nil
                && activeTab.addressDraft.isEmpty && activeTab.inputError == nil && activeTab.restorationNotice == nil
                && (activeTab.storedTitle.isEmpty || activeTab.storedTitle == "新しいタブ")
            guard blank || tabs.count < 1000 else { rejected = true; continue }
            let tab = blank ? activeTab : BrowserTab()
            tab.pendingURL = url
            tab.addressDraft = url.absoluteString
            tab.storedTitle = url.host ?? "ページ"
            if !blank { tabs.append(tab) }
            last = tab.id
        }
        if let last {
            selectedID = last
            // This is an explicit external request, even during crash recovery.
            // Other restored and newly received tabs remain unloaded.
            activatePendingTab()
            persistSession()
        }
        if rejected {
            externalOpenNotice = "一部のリンクを開けませんでした。HTTP/HTTPSのリンクだけを受け取り、タブ一覧は1000件まで保存できます。"
        }
    }

    func moveTabs(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, source.allSatisfy({ tabs.indices.contains($0) }),
              (0...tabs.count).contains(destination) else { return }
        let moving = source.sorted().map { tabs[$0] }
        let adjusted = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { tabs.remove(at: index) }
        tabs.insert(contentsOf: moving, at: adjusted)
        persistSession()
    }

    func moveTab(_ id: UUID, by offset: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(source + offset) else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: source + offset)
        persistSession()
    }

    var editedTabCount: Int { tabs.filter { $0.page?.inputGuard.hasEditedInput == true }.count }

    func confirmEditedInputForQuit() -> Bool {
        let count = editedTabCount
        return count == 0 || confirmInputDiscard(tabCount: count, quitting: true)
    }

    private func confirmInputDiscard(tabCount: Int, quitting: Bool, context: String? = nil) -> Bool {
        guard !inputConfirmationInProgress else { return false }
        inputConfirmationInProgress = true
        defer { inputConfirmationInProgress = false }
        return PageInputGuard.confirmDiscard(tabCount: tabCount, quitting: quitting, context: context)
    }

    func closeTab(_ id: UUID, selectingAfterClose preferredID: UUID? = nil, confirmEditedInput: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if downloads.hasActive(tabID: id) {
            selectedID = id
            downloads.notice = "ダウンロード中です。転送を取り消すか、完了してからタブを閉じてください。"
            return
        }
        if confirmEditedInput, tab.page?.inputGuard.hasEditedInput == true {
            selectedID = id
            guard confirmInputDiscard(tabCount: 1, quitting: false, context: tab.displayTitle) else {
                if tabs.contains(where: { $0 === tab }) { selectedID = id; persistSession() }
                return
            }
        }
        // NSAlert runs a nested event loop. External URLs or script callbacks may
        // have changed the list while the confirmation was open.
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if downloads.hasActive(tabID: id) {
            selectedID = id
            downloads.notice = "ダウンロード中です。転送を取り消すか、完了してからタブを閉じてください。"
            return
        }
        tab.page?.dialogs.cancel()
        tab.page?.cancelFileSelection()
        closedTabs.append(ClosedTab(isLocalPDF: tab.isLocalPDF, url: tab.isLocalPDF ? nil : (tab.page?.url ?? tab.pendingURL), draft: tab.isLocalPDF ? "" : tab.addressDraft,
                                    mayReload: tab.page?.canRetry ?? tab.mayRestoreAutomatically, index: index))
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tab.page?.stop()
        tab.page = nil
        tabs.remove(at: index)
        if tabs.isEmpty {
            let blank = BrowserTab()
            tabs = [blank]
            selectedID = blank.id
            addressFocusRequest += 1
        } else if selectedID == id {
            if let preferredID, tabs.contains(where: { $0.id == preferredID }) { selectedID = preferredID }
            else { selectedID = tabs[min(index, tabs.count - 1)].id }
        }
        if !recoveryRequired { activatePendingTab() }
        persistSession()
    }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = BrowserTab()
        tab.isLocalPDF = closed.isLocalPDF
        if closed.isLocalPDF {
            tab.storedTitle = "ローカルPDF"
            tab.restorationNotice = "ローカルPDFは保存していません。ファイルを選び直してください。"
        }
        tab.addressDraft = closed.url?.absoluteString ?? closed.draft
        tabs.insert(tab, at: min(closed.index, tabs.count))
        selectedID = tab.id
        if let url = closed.url, closed.mayReload {
            _ = navigate(url.absoluteString)
            tab.restorationNotice = "ページを読み込み直しました。閉じる前の入力内容は復元されません。"
        } else if closed.url != nil {
            tab.restorationNotice = "送信後のページです。URLを確認してから開いてください。"
            tab.pendingURL = closed.url
            tab.mayRestoreAutomatically = false
            addressFocusRequest += 1
        }
        persistSession()
    }

    func showFind() {
        guard page != nil else { return }
        activeTab.isFindBarVisible = true
        findFocusRequest += 1
    }

    private func connect(_ runtime: PageRuntime, to tab: BrowserTab) {
        runtime.onVisit = { [weak self, weak tab] url, title, visited in
            guard let self, let tab, self.tabs.contains(where: { $0 === tab }) else { return }
            self.history.record(url: url, title: title, visited: visited)
        }
        runtime.onVisitTitle = { [weak self, weak tab] url, title, visited in
            guard let self, let tab, self.tabs.contains(where: { $0 === tab }) else { return }
            self.history.updateTitle(url: url, title: title, visited: visited)
        }
        runtime.onDownload = { [weak self, weak tab] download in
            guard let self, let tab else { download.cancel { _ in }; return }
            self.downloads.accept(download, tabID: tab.id)
        }
        runtime.onMetadataChange = { [weak self, weak tab] in
            guard let self, let tab, self.tabs.contains(where: { $0 === tab }) else { return }
            self.schedulePersistence()
        }
        runtime.onCreatePage = { [weak self, weak tab] configuration, origin, foreground in
            guard let self, let tab else { return nil }
            return self.openRelatedPage(configuration: configuration, openerID: tab.id,
                                        origin: origin, foreground: foreground)?.webView
        }
        runtime.onOpenLink = { [weak self, weak tab] request, foreground, origin in
            guard let self, let tab else { return }
            self.openLink(request, openerID: tab.id, origin: origin, foreground: foreground)
        }
        runtime.onClose = { [weak self, weak tab] in
            guard let self, let tab, let openerID = tab.openerID,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            // WebKit sends this after DOM window.close() has completed. The
            // native view cannot undo that close or promise to preserve editing.
            self.closeTab(tab.id, selectingAfterClose: openerID, confirmEditedInput: false)
        }
    }

    @discardableResult
    func openRelatedPage(configuration: WKWebViewConfiguration, openerID: UUID,
                         origin: String, foreground: Bool) -> PageRuntime? {
        guard let index = tabs.firstIndex(where: { $0.id == openerID }) else { return nil }
        let tab = BrowserTab()
        tab.openerID = openerID
        tab.openerOrigin = origin
        let runtime = PageRuntime(configuration: configuration, permitsInitialBlankPage: true)
        connect(runtime, to: tab)
        tab.page = runtime
        tabs.insert(tab, at: index + 1)
        if foreground { selectedID = tab.id }
        persistSession()
        return runtime
    }

    func openLink(_ request: URLRequest, openerID: UUID, origin: String, foreground: Bool) {
        guard request.httpMethod == "GET", NavigationPolicy.allows(request.url, isMainFrame: true),
              let opener = tabs.first(where: { $0.id == openerID }), let dataStore = opener.page?.webView.configuration.websiteDataStore,
              let index = tabs.firstIndex(where: { $0.id == openerID }) else { return }
        let tab = BrowserTab()
        tab.openerOrigin = origin
        let runtime = PageRuntime(dataStore: dataStore)
        connect(runtime, to: tab)
        tab.page = runtime
        runtime.load(request)
        tabs.insert(tab, at: index + 1)
        if foreground { selectedID = tab.id }
        persistSession()
    }

    private func websiteDataStore() -> WKWebsiteDataStore {
        if let dataStore { return dataStore }
        let isolated = ProcessInfo.processInfo.environment["LEVISTICA_EPHEMERAL"] == "1"
        let value: WKWebsiteDataStore = isolated ? .nonPersistent() : .default()
        dataStore = value
        return value
    }

    func chooseLocalPDF(replacing id: UUID? = nil) {
        guard localPDFPanel == nil, let window = NSApp.keyWindow, window.attachedSheet == nil else { return }
        let panel = LocalPDF.panel()
        localPDFPanel = panel
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self else { return }
            self.localPDFPanel = nil
            guard result == .OK, let url = panel.url else { return }
            do { try self.openLocalPDF(selectedURL: url, replacing: id) }
            catch { self.externalOpenNotice = error.localizedDescription }
        }
    }

    func openLocalPDF(selectedURL: URL, replacing id: UUID? = nil) throws {
        // Validate before altering selection or creating a tab. A cancelled or
        // rejected choice must leave the current page and its input untouched.
        let document = try LocalPDF(selectedURL: selectedURL)
        let tab: BrowserTab
        if let id {
            guard let existing = tabs.first(where: { $0.id == id }), existing.isLocalPDF, existing.page == nil else { return }
            tab = existing
        } else if tabs.count == 1, activeTab.page == nil, activeTab.pendingURL == nil,
                  activeTab.addressDraft.isEmpty, activeTab.inputError == nil,
                  activeTab.restorationNotice == nil, !activeTab.isLocalPDF {
            tab = activeTab
        } else {
            tab = BrowserTab()
            tabs.append(tab)
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore()
        let runtime = PageRuntime(configuration: configuration, localPDF: document)
        connect(runtime, to: tab)
        tab.isLocalPDF = true
        tab.storedTitle = document.url.lastPathComponent
        tab.restorationNotice = nil
        tab.inputError = nil
        tab.pendingURL = nil
        tab.addressDraft = document.url.absoluteString
        tab.page = runtime
        selectedID = tab.id
        runtime.loadLocalPDF()
        persistSession()
    }

    func navigate(_ input: String) -> Bool {
        do {
            let url = try AddressResolver.resolve(input)
            let tab = activeTab
            tab.inputError = nil
            tab.restorationNotice = nil
            tab.pendingURL = nil
            if tab.isLocalPDF {
                tab.page?.stop()
                tab.page = nil
                tab.isLocalPDF = false
            }
            tab.addressDraft = url.absoluteString
            if tab.page == nil {
                let runtime = PageRuntime(dataStore: websiteDataStore())
                connect(runtime, to: tab)
                tab.page = runtime
            }
            tab.page?.load(url)
            persistSession()
            return true
        } catch {
            activeTab.inputError = error.localizedDescription
            return false
        }
    }
}
