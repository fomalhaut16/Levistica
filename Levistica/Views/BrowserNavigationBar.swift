import SwiftUI

struct BrowserNavigationBar: View {
    @Bindable var session: BrowserSession
    @Bindable var tab: BrowserTab
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button("閲覧履歴", systemImage: "clock") { session.showHistory() }
                .accessibilityIdentifier("showHistoryButton")
            Button("ブックマーク", systemImage: "book") { session.showBookmarks() }
                .accessibilityIdentifier("showBookmarksButton")
            Button("戻る", systemImage: "chevron.left") { tab.page?.back() }
                .disabled(tab.page?.canGoBack != true).accessibilityIdentifier("backButton")
            Button("進む", systemImage: "chevron.right") { tab.page?.forward() }
                .disabled(tab.page?.canGoForward != true).accessibilityIdentifier("forwardButton")
            TextField("URLまたは検索語を入力", text: $tab.addressDraft)
                .textFieldStyle(.roundedBorder).focused($addressFocused)
                .accessibilityIdentifier("addressField")
                .onSubmit {
                    if session.navigate(tab.addressDraft) { addressFocused = false }
                }
                .onExitCommand {
                    tab.addressDraft = (tab.page?.url ?? tab.pendingURL)?.absoluteString ?? ""
                    addressFocused = false
                }
            if tab.page?.isLoading == true {
                Button("停止", systemImage: "xmark") { tab.page?.stop() }
                    .accessibilityIdentifier("stopButton")
            } else {
                Button("再読み込み", systemImage: "arrow.clockwise") { tab.page?.reload() }
                    .disabled(tab.page == nil).accessibilityIdentifier("reloadButton")
            }
        }
        .labelStyle(.iconOnly).padding(10)
        .onAppear {
            if let url = tab.page?.url { tab.addressDraft = url.absoluteString }
            addressFocused = tab.page == nil && !tab.isSleeping
        }
        .onChange(of: session.addressFocusRequest) { addressFocused = true }
        .onChange(of: tab.page?.url) { _, url in
            if !addressFocused { tab.addressDraft = (url ?? tab.pendingURL)?.absoluteString ?? "" }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused, tab.inputError == nil, let url = tab.page?.url { tab.addressDraft = url.absoluteString }
        }
    }
}
