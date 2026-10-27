import SwiftUI

struct BrowserNavigationBar: View {
    @Bindable var session: BrowserSession
    @Bindable var tab: BrowserTab
    @FocusState private var addressFocused: Bool
    @State private var layoutSaveFailed = false

    var body: some View {
        HStack(spacing: 10) {
            Button(session.preferences.tabLayout == .vertical ? "横タブに切り替え" : "縦タブに切り替え",
                   systemImage: session.preferences.tabLayout == .vertical ? "rectangle.topthird.inset.filled" : "sidebar.left") {
                layoutSaveFailed = !session.preferences.saveTabLayout(session.preferences.tabLayout == .vertical ? .horizontal : .vertical)
            }
            .help(session.preferences.tabLayout == .vertical ? "横タブに切り替え" : "縦タブに切り替え")
            .disabled(!session.preferences.canSave)
            .accessibilityIdentifier("toggleTabLayoutButton")
            Button("閲覧履歴", systemImage: "clock") { session.showHistory() }
                .accessibilityIdentifier("showHistoryButton")
            Button("ブックマーク", systemImage: "book") { session.showBookmarks() }
                .accessibilityIdentifier("showBookmarksButton")
            Button("戻る", systemImage: "chevron.left") { tab.page?.back() }
                .disabled(tab.page?.canGoBack != true).accessibilityIdentifier("backButton")
            Button("進む", systemImage: "chevron.right") { tab.page?.forward() }
                .disabled(tab.page?.canGoForward != true).accessibilityIdentifier("forwardButton")
            TextField("URLまたは検索語を入力", text: Binding(
                get: { tab.addressDraft },
                set: {
                    guard $0 != tab.addressDraft else { return }
                    tab.hasEditedAddress = true
                    tab.addressDraft = $0
                }
            ))
                .textFieldStyle(.roundedBorder).focused($addressFocused)
                .accessibilityIdentifier("addressField")
                .onSubmit {
                    if session.navigate(tab.addressDraft) { addressFocused = false }
                }
                .onExitCommand {
                    tab.addressDraft = (tab.page?.url ?? tab.pendingURL)?.absoluteString ?? ""
                    tab.hasEditedAddress = false
                    tab.inputError = nil
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
        .alert("タブの配置を保存できませんでした", isPresented: $layoutSaveFailed) {
            Button("閉じる", role: .cancel) { }
        } message: {
            Text("これまでの配置を使います。一般設定の保存先を確認してください。")
        }
        .onAppear {
            if !tab.hasEditedAddress, let url = tab.page?.url { tab.addressDraft = url.absoluteString }
            addressFocused = tab.page == nil && !tab.isSleeping
        }
        .onChange(of: session.addressFocusRequest) { addressFocused = true }
        .onChange(of: tab.page?.url) { _, url in
            // Page redirects and same-document routes must not replace an
            // unfinished address. Successful submission or Escape ends editing.
            guard !tab.hasEditedAddress else { return }
            tab.addressDraft = (url ?? tab.pendingURL)?.absoluteString ?? ""
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused, !tab.hasEditedAddress, tab.inputError == nil, let url = tab.page?.url { tab.addressDraft = url.absoluteString }
        }
    }
}
