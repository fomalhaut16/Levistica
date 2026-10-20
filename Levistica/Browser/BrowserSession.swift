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
    private var closedTabs: [ClosedTab] = []

    private struct ClosedTab {
        let url: URL?
        let draft: String
        let mayReload: Bool
        let index: Int
    }

    init(dataStore: WKWebsiteDataStore? = nil) {
        let tab = BrowserTab()
        tabs = [tab]
        selectedID = tab.id
        self.dataStore = dataStore
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
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func selectAdjacent(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        selectedID = tabs[(index + offset % tabs.count + tabs.count) % tabs.count].id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        closedTabs.append(ClosedTab(url: tab.page?.url, draft: tab.addressDraft,
                                    mayReload: tab.page?.canRetry == true, index: index))
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
            addressFocusRequest += 1
        }
    }

    func showFind() {
        guard page != nil else { return }
        activeTab.isFindBarVisible = true
        findFocusRequest += 1
    }

    func navigate(_ input: String) -> Bool {
        do {
            let url = try AddressResolver.resolve(input)
            let tab = activeTab
            tab.inputError = nil
            tab.restorationNotice = nil
            tab.addressDraft = url.absoluteString
            if tab.page == nil {
                if dataStore == nil {
                    let isolated = ProcessInfo.processInfo.environment["LEVISTICA_EPHEMERAL"] == "1"
                    dataStore = isolated ? .nonPersistent() : .default()
                }
                if let dataStore { tab.page = PageRuntime(dataStore: dataStore) }
            }
            tab.page?.load(url)
            return true
        } catch {
            activeTab.inputError = error.localizedDescription
            return false
        }
    }
}
