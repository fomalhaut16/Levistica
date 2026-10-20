import Observation
import WebKit

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
    var discardUnsavedChangesOnQuit = false
    private var closedTabs: [ClosedTab] = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    private struct ClosedTab {
        let url: URL?
        let draft: String
        let mayReload: Bool
        let index: Int
    }

    init(dataStore: WKWebsiteDataStore? = nil, store: SessionStore? = nil) {
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
        do {
            var folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
                .appendingPathComponent("Levistica", isDirectory: true)
            if let testID { folder.append(path: "SessionTests/" + testID.uuidString, directoryHint: .isDirectory) }
            return BrowserSession(store: try SessionStore(fileURL: folder.appendingPathComponent("session.sqlite3")))
        } catch {
            let session = BrowserSession()
            session.storageFailure = "タブ一覧の保存先を開けませんでした。この起動ではタブ一覧を保存しません。"
            return session
        }
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
        pendingSave?.cancel()
        pendingSave = nil
        guard let store, !persistenceDisabled, !discardUnsavedChangesOnQuit else { return true }
        do {
            try store.save(snapshot(wasRunning: false))
            storageFailure = nil
            return true
        } catch {
            storageFailure = "タブ一覧を保存できないため終了を取り消しました。再試行するか、保存せず終了を選んでください。"
            return false
        }
    }

    private func snapshot(wasRunning: Bool) -> SavedSession {
        SavedSession(tabs: tabs.map { tab in
            SavedTab(id: tab.id, title: tab.displayTitle, url: tab.page?.url ?? tab.pendingURL,
                     mayReload: tab.page?.canRetry ?? tab.mayRestoreAutomatically)
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

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        closedTabs.append(ClosedTab(url: tab.page?.url ?? tab.pendingURL, draft: tab.addressDraft,
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
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        if !recoveryRequired { activatePendingTab() }
        persistSession()
    }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        let tab = BrowserTab()
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
            let wasSelected = self.selectedID == tab.id
            self.closeTab(tab.id)
            if wasSelected { self.select(openerID) }
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

    func navigate(_ input: String) -> Bool {
        do {
            let url = try AddressResolver.resolve(input)
            let tab = activeTab
            tab.inputError = nil
            tab.restorationNotice = nil
            tab.pendingURL = nil
            tab.addressDraft = url.absoluteString
            if tab.page == nil {
                if dataStore == nil {
                    let isolated = ProcessInfo.processInfo.environment["LEVISTICA_EPHEMERAL"] == "1"
                    dataStore = isolated ? .nonPersistent() : .default()
                }
                if let dataStore {
                    let runtime = PageRuntime(dataStore: dataStore)
                    connect(runtime, to: tab)
                    tab.page = runtime
                }
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
