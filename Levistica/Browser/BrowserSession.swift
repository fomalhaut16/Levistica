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
    private var store: SessionStore?
    private var persistenceDisabled = false
    private var initialSelectionActivated = false
    private(set) var recoveryRequired = false
    private(set) var recoveryMessage = "前回は正常に終了しませんでした。タブ一覧だけを復元しました。"
    private(set) var storageFailure: String?
    private(set) var backupFailure: String?
    private(set) var recoveryBackupDate: Date?
    private(set) var recoveryBackupTabCount: Int?
    private var recoveryFileURL: URL?
    private var recoveryBlankTabID: UUID?
    var hasStorageRecoverySource: Bool { recoveryFileURL != nil }
    var canRetryPersistence: Bool { store != nil && !persistenceDisabled }
    var canRestoreSessionBackup: Bool {
        recoveryFileURL != nil && recoveryBackupTabCount != nil && tabs.count == 1
            && selectedID == recoveryBlankTabID && activeTab.page == nil && activeTab.pendingURL == nil
            && activeTab.addressDraft.isEmpty && closedTabs.isEmpty
            && !downloads.hasActive && !isDeletingSiteData
    }
    var externalOpenNotice: String?
    var discardUnsavedChangesOnQuit = false
    private var sleepRequestID: UUID?
    @ObservationIgnored private var sleepProbeID: UUID?
    @ObservationIgnored private weak var sleepTargetTab: BrowserTab?
    private var closedTabs: [ClosedTab] = []
    @ObservationIgnored private var inputConfirmationInProgress = false
    let downloads = DownloadManager()
    @ObservationIgnored private var siteDataModel: SiteDataLibrary?
    var isDeletingSiteData: Bool { siteDataModel?.isDeleting == true }
    enum SettingsSection: Hashable { case general, history, siteData }
    var settingsSection = SettingsSection.general
    let preferences: BrowserPreferences
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
        let isKept: Bool
        let index: Int
    }

    init(dataStore: WKWebsiteDataStore? = nil, store: SessionStore? = nil, bookmarkFileURL: URL? = nil, historyFileURL: URL? = nil,
         preferencesFileURL: URL? = nil) {
        preferences = BrowserPreferences(fileURL: preferencesFileURL)
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
                    install(saved, requireConfirmation: saved.wasRunning)
                } else if FileManager.default.fileExists(atPath: store.backupURL.path)
                            || store.dataFileURL.lastPathComponent.hasPrefix("recovered-session-") {
                    throw SessionStore.Failure.invalidData
                }
                persistSession()
            } catch {
                persistenceDisabled = true
                storageFailure = "前回のタブ一覧を読み込めませんでした。保存データを残して起動しています。この起動では保存しません。"
                self.store = nil
                configureRecovery(from: store.dataFileURL, error: error)
            }
        }
    }

    static func applicationSession() -> BrowserSession {
        #if LEVISTICA_PROFILE || LEVISTICA_MEASUREMENT
        return BrowserSession()
        #else
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
            #if DEBUG
            if testID != nil && environment["LEVISTICA_EPHEMERAL"] == "1",
               let value = environment["LEVISTICA_SESSION_FIXTURE_BASE"],
               let base = URLComponents(string: value), base.scheme == "http", base.host == "127.0.0.1",
               base.port != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
               base.path.isEmpty || base.path == "/", let url = base.url {
                if environment["LEVISTICA_RECOVERY_FIXTURE"] == "1" {
                    try seedRecoveryFixture(in: folder, base: url)
                } else if let rawCount = environment["LEVISTICA_LARGE_SESSION_FIXTURE"],
                          ["50", "100"].contains(rawCount), let count = Int(rawCount) {
                    try seedLargeSessionFixture(in: folder, base: url, count: count)
                }
            }
            #endif
            return persistentSession(in: folder)
        } catch {
            let session = BrowserSession()
            session.storageFailure = "タブ一覧の保存先を開けませんでした。この起動ではタブ一覧を保存しません。"
            return session
        }
        #endif
    }

    #if DEBUG
    private static func seedLargeSessionFixture(in folder: URL, base: URL, count: Int) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path),
           !(try manager.contentsOfDirectory(atPath: folder.path)).isEmpty { return }
        guard [50, 100].contains(count) else { throw SessionStore.Failure.invalidData }
        let tabs = try (1...count).map { number in
            guard var location = URLComponents(url: base.appendingPathComponent(number == 1 ? "two" : "one"), resolvingAgainstBaseURL: false) else {
                throw SessionStore.Failure.invalidData
            }
            location.fragment = "tab-\(number)"
            return SavedTab(id: UUID(), title: String(format: "Scale tab %03d", number),
                            url: location.url, mayReload: true)
        }
        let store = try SessionStore(fileURL: folder.appendingPathComponent("session.sqlite3"))
        try store.save(SavedSession(tabs: tabs, selectedID: tabs[0].id, wasRunning: false))
    }

    // Only fresh UUID-scoped, ephemeral Debug sessions may create this synthetic fixture.
    private static func seedRecoveryFixture(in folder: URL, base: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: folder.path),
           !(try manager.contentsOfDirectory(atPath: folder.path)).isEmpty { return }
        let file = folder.appendingPathComponent("session.sqlite3")
        let first = SavedTab(id: UUID(), title: "Fixture one", url: base.appendingPathComponent("one"), mayReload: true)
        let second = SavedTab(id: UUID(), title: "Fixture two", url: base.appendingPathComponent("two"),
                              mayReload: true, isKept: true, isSleeping: true)
        let store = try SessionStore(fileURL: file)
        try store.save(SavedSession(tabs: [first, second], selectedID: first.id, wasRunning: false))
        try store.writeCleanBackup()
        try Data("isolated unreadable session fixture".utf8).write(to: file, options: .atomic)
    }
    #endif

    static func persistentSession(in folder: URL, dataStore: WKWebsiteDataStore? = nil) -> BrowserSession {
        let bookmarkURL = folder.appendingPathComponent("bookmarks.sqlite3")
        let historyURL = folder.appendingPathComponent("history.sqlite3")
        let preferencesURL = folder.appendingPathComponent("browser-preferences.json")
        var resolved: URL?
        do {
            let file = try SessionStore.currentFileURL(in: folder)
            resolved = file
            let manager = FileManager.default
            let exists = manager.fileExists(atPath: file.path)
            let size = (try? manager.attributesOfItem(atPath: file.path)[.size]) as? NSNumber
            if (!exists || size?.intValue == 0),
               (file.lastPathComponent != "session.sqlite3" || manager.fileExists(atPath: file.path + ".backup")) {
                throw SessionStore.Failure.invalidData
            }
            return BrowserSession(dataStore: dataStore, store: try SessionStore(fileURL: file),
                                  bookmarkFileURL: bookmarkURL, historyFileURL: historyURL, preferencesFileURL: preferencesURL)
        } catch {
            let session = BrowserSession(dataStore: dataStore, bookmarkFileURL: bookmarkURL, historyFileURL: historyURL,
                                         preferencesFileURL: preferencesURL)
            session.storageFailure = "タブ一覧の保存先を開けませんでした。この起動ではタブ一覧を保存しません。"
            session.configureRecovery(from: resolved, error: error)
            return session
        }
    }

    private func install(_ saved: SavedSession, requireConfirmation: Bool) {
        tabs = saved.tabs.map { record in
            let restored = BrowserTab(id: record.id)
            restored.isLocalPDF = record.kind == .localPDF
            restored.isKept = record.isKept
            restored.isSleeping = record.isSleeping
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
        recoveryRequired = requireConfirmation
    }

    private func configureRecovery(from file: URL?, error: Error) {
        if let failure = error as? SessionStore.Failure, case .newerVersion = failure {
            storageFailure = "このアプリより新しい形式のタブ一覧です。保存ファイルを残しています。この起動では一覧を保存しません。"
            return
        }
        guard let file else { return }
        recoveryFileURL = file
        recoveryBlankTabID = selectedID
        guard let saved = try? SessionStore.readCleanBackup(of: file) else { return }
        recoveryBackupTabCount = saved.tabs.count
        recoveryBackupDate = (try? FileManager.default.attributesOfItem(atPath: file.path + ".backup")[.modificationDate]) as? Date
    }

    @discardableResult
    func restoreSessionBackup() -> Bool {
        guard canRestoreSessionBackup, let file = recoveryFileURL else { return false }
        do {
            let recovered = try SessionStore.recoverCleanBackup(of: file)
            guard let saved = try recovered.load() else { throw SessionStore.Failure.invalidData }
            store = recovered
            persistenceDisabled = false
            install(saved, requireConfirmation: true)
            recoveryMessage = "バックアップからタブ一覧を復旧しました。ページを開くか選べます。"
            recoveryFileURL = nil
            recoveryBlankTabID = nil
            recoveryBackupDate = nil
            recoveryBackupTabCount = nil
            storageFailure = nil
            backupFailure = nil
            return true
        } catch {
            storageFailure = "バックアップから一覧を復旧できませんでした。元の保存ファイルを残しています。"
            return false
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

    func siteDataLibrary() -> SiteDataLibrary {
        if let siteDataModel { return siteDataModel }
        let value = SiteDataLibrary { [weak self] in self?.websiteDataStore() }
        siteDataModel = value
        return value
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
        guard !tab.isSleeping, let url = tab.pendingURL, tab.mayRestoreAutomatically else { return }
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
        if downloads.hasActive || isDeletingSiteData { return false }
        pendingSave?.cancel()
        pendingSave = nil
        guard let store, !persistenceDisabled, !discardUnsavedChangesOnQuit else {
            dismissPageDialogs()
            return true
        }
        do {
            try store.save(snapshot(wasRunning: false))
            storageFailure = nil
            do {
                try store.writeCleanBackup()
                backupFailure = nil
            } catch {
                // The primary save succeeded. Keep the previous backup and allow quit.
                backupFailure = "タブ一覧を保存しました。復旧用のバックアップは更新できませんでした。"
            }
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
                     kind: tab.isLocalPDF ? .localPDF : .web, isKept: tab.isKept, isSleeping: tab.isSleeping)
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
        if let url = preferences.newTabURL { _ = navigate(url.absoluteString) }
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        activeTab.isSleeping = false
        resumeSelectedTab()
        persistSession()
    }

    func toggleKeep(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isKept.toggle()
        persistSession()
    }

    var isRequestingSleep: Bool { sleepRequestID != nil }

    func sleepBlockReason(_ tab: BrowserTab) -> String? {
        if isDeletingSiteData { return "サイトデータを削除中です。完了してから操作してください。" }
        if tab.isKept { return "保持する設定のタブです。休眠するには保持を解除してください。" }
        guard let page = tab.page else { return "このタブはまだ読み込まれていません。" }
        if page.inputGuard.hasEditedInput { return "入力操作のあったタブは休眠しません。保存・送信後にページを開き直してください。" }
        if downloads.hasActive(tabID: tab.id) { return "ダウンロード中のタブは休眠しません。完了するか、転送を取り消してください。" }
        if page.webView.fullscreenState != .notInFullscreen { return "全画面表示を終了してから休眠してください。" }
        if page.isChoosingFile { return "ファイルを選択中のタブは休眠しません。" }
        if page.isLoading || page.webView.isLoading { return "読み込み中のタブは休眠しません。" }
        if tab.isLocalPDF || page.isPDF { return "PDFの表示・入力状態を保護するため、このタブは休眠しません。" }
        if tab.openerID != nil || tab.openerOrigin != nil || tabs.contains(where: { $0.openerID == tab.id }) {
            return "別タブと連携するページは休眠しません。"
        }
        if tab.hasEditedAddress && tab.addressDraft != page.url?.absoluteString { return "URL欄を編集中です。ページに戻ってから操作してください。" }
        if page.failure != nil || !page.canRetry || SessionStore.persistableURL(page.url) == nil {
            return "URLから安全に読み込み直せることを確認できないため、休眠しません。"
        }
        if page.webView.cameraCaptureState != .none || page.webView.microphoneCaptureState != .none {
            return "カメラ・マイクを使用するタブは休眠しません。"
        }
        return nil
    }

    func requestSelectedTabSleep() {
        let tab = activeTab
        guard sleepRequestID == nil else { return }
        if let reason = sleepBlockReason(tab) { tab.sleepNotice = reason; return }
        guard let page = tab.page, let url = page.url else { return }
        tab.sleepNotice = nil
        sleepTargetTab = tab
        let revision = page.documentRevision
        let request = UUID()
        sleepRequestID = request
        let isCurrent: @MainActor () -> Bool = { [weak self, weak tab, weak page] in
            guard let self, let tab, let page else { return false }
            return self.sleepRequestID == request && self.selectedID == tab.id
                && self.tabs.contains(where: { $0 === tab }) && tab.page === page
                && page.documentRevision == revision && page.url == url && page.webView.url == url
                && self.sleepBlockReason(tab) == nil
        }
        probeSleepMedia(page, request: request) { [weak self, weak tab, weak page] state in
            guard let self else { return }
            guard let tab, let page else { self.finishSleepRequest(request); return }
            guard state == WKMediaPlaybackState.none, isCurrent() else {
                self.finishSleepRequest(request, notice: "ページの状態を確認できないか、メディアや保護対象があります。休眠を取り消しました。")
                return
            }
            page.dialogs.confirmSleep(window: page.webView.window) { [weak self, weak tab, weak page] allowed in
                guard let self else { return }
                guard let tab, let page else { self.finishSleepRequest(request); return }
                guard allowed, isCurrent() else { self.finishSleepRequest(request); return }
                // Recheck after the sheet: navigation, input, transfers, or playback
                // may have changed while the user was deciding.
                self.probeSleepMedia(page, request: request) { [weak self, weak tab, weak page] state in
                    guard let self else { return }
                    guard let tab, let page else { self.finishSleepRequest(request); return }
                    guard state == WKMediaPlaybackState.none, isCurrent() else {
                        self.finishSleepRequest(request, notice: "ページの状態が変わったため、休眠を取り消しました。")
                        return
                    }
                    tab.pendingURL = url
                    tab.storedTitle = tab.displayTitle
                    tab.mayRestoreAutomatically = true
                    tab.isSleeping = true
                    tab.isFindBarVisible = false
                    page.stop()
                    page.cancelFileSelection()
                    page.webView.removeFromSuperview()
                    tab.page = nil
                    self.finishSleepRequest(request)
                    self.persistSession()
                }
            }
        }
    }

    private func probeSleepMedia(_ page: PageRuntime, request: UUID,
                                 completion: @escaping @MainActor (WKMediaPlaybackState?) -> Void) {
        let probe = UUID()
        sleepProbeID = probe
        page.webView.requestMediaPlaybackState { [weak self] state in
            guard let self, self.sleepRequestID == request, self.sleepProbeID == probe else { return }
            self.sleepProbeID = nil
            completion(state)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.sleepRequestID == request, self.sleepProbeID == probe else { return }
            self.sleepProbeID = nil
            completion(nil)
        }
    }

    private func finishSleepRequest(_ request: UUID, notice: String? = nil) {
        guard sleepRequestID == request else { return }
        sleepRequestID = nil
        sleepProbeID = nil
        if let notice { sleepTargetTab?.sleepNotice = notice }
        sleepTargetTab = nil
    }

    func resumeSleepingTab() {
        guard activeTab.isSleeping else { return }
        activeTab.isSleeping = false
        activatePendingTab()
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
                                    mayReload: tab.page?.canRetry ?? tab.mayRestoreAutomatically, isKept: tab.isKept, index: index))
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
        tab.isKept = closed.isKept
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
        #if LEVISTICA_PROFILE || LEVISTICA_MEASUREMENT
        let value = WKWebsiteDataStore.nonPersistent()
        #else
        let isolated = ProcessInfo.processInfo.environment["LEVISTICA_EPHEMERAL"] == "1"
        let value: WKWebsiteDataStore = isolated ? .nonPersistent() : .default()
        #endif
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
            tab.isSleeping = false
            tab.restorationNotice = nil
            tab.pendingURL = nil
            if tab.isLocalPDF {
                tab.page?.stop()
                tab.page = nil
                tab.isLocalPDF = false
            }
            tab.addressDraft = url.absoluteString
            tab.hasEditedAddress = false
            if tab.page == nil {
                let runtime = PageRuntime(dataStore: websiteDataStore())
                connect(runtime, to: tab)
                tab.page = runtime
            }
            tab.page?.load(url)
            // A protected document still owns its committed URL until the user
            // allows departure. Do not display the submitted destination early.
            tab.addressDraft = tab.page?.url?.absoluteString ?? url.absoluteString
            persistSession()
            return true
        } catch {
            activeTab.inputError = error.localizedDescription
            return false
        }
    }
}
