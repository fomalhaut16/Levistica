import SwiftUI

struct BrowserNavigationBar: View {
    @Bindable var session: BrowserSession
    @Bindable var tab: BrowserTab
    @FocusState private var addressFocused: Bool
    @State private var layoutSaveFailed = false

    var body: some View {
        HStack(spacing: 8) {
            Button("戻る", systemImage: "chevron.left") { tab.page?.back() }
                .disabled(tab.page?.canGoBack != true).accessibilityIdentifier("backButton").help("戻る（Cmd-[）")
            Button("進む", systemImage: "chevron.right") { tab.page?.forward() }
                .disabled(tab.page?.canGoForward != true).accessibilityIdentifier("forwardButton").help("進む（Cmd-]）")
            if tab.page?.isLoading == true {
                Button("停止", systemImage: "xmark") { tab.page?.stop() }
                    .accessibilityIdentifier("stopButton").help("読み込みを停止")
            } else {
                Button("再読み込み", systemImage: "arrow.clockwise") { tab.page?.reload() }
                    .disabled(tab.page == nil).accessibilityIdentifier("reloadButton").help("再読み込み")
            }
            PageConnectionBadge(info: tab.page?.connectionInfo)
            TextField("URLまたは検索語を入力", text: Binding(
                get: { tab.addressDraft },
                set: {
                    guard $0 != tab.addressDraft else { return }
                    tab.hasEditedAddress = true
                    tab.addressDraft = $0
                }
            ))
                .textFieldStyle(.roundedBorder).focused($addressFocused)
                .frame(minWidth: 180).layoutPriority(1)
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
            Button(session.preferences.tabLayout == .vertical ? "横タブに切り替え" : "縦タブに切り替え",
                   systemImage: session.preferences.tabLayout == .vertical ? "rectangle.topthird.inset.filled" : "sidebar.left") {
                layoutSaveFailed = !session.preferences.saveTabLayout(session.preferences.tabLayout == .vertical ? .horizontal : .vertical)
            }
            .help(session.preferences.tabLayout == .vertical ? "横タブに切り替え" : "縦タブに切り替え")
            .disabled(!session.preferences.canSave)
            .accessibilityIdentifier("toggleTabLayoutButton")
            Button("閲覧履歴", systemImage: "clock") { session.showHistory() }
                .accessibilityIdentifier("showHistoryButton").help("閲覧履歴（Cmd-Y）")
            Button("ブックマーク", systemImage: "book") { session.showBookmarks() }
                .accessibilityIdentifier("showBookmarksButton").help("ブックマーク一覧")

        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
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


private struct PageConnectionBadge: View {
    let info: PageConnectionInfo?
    @State private var showingDetails = false
    private var kind: PageConnectionInfo.Kind { info?.kind ?? .none }
    private var title: String {
        switch kind {
        case .none: "接続"
        case .loading: "確認中"
        case .http: "HTTP"
        case .https: "HTTPS"
        case .mixedContent: "混在"
        case .localPDF: "PDF"
        case .unavailable: "未確認"
        }
    }
    private var symbol: String {
        switch kind {
        case .http, .mixedContent, .unavailable: "exclamationmark.triangle"
        case .https: "network"
        case .localPDF: "doc"
        default: "info.circle"
        }
    }
    private var explanation: String {
        switch kind {
        case .none: "読み込み済みのページがありません。"
        case .loading: "読み込み中です。接続情報の更新を待っています。"
        case .http: "HTTP接続です。通信内容は暗号化されていません。"
        case .https: "HTTPS接続です。ページ内容の正当性は別に確認してください。"
        case .mixedContent: "HTTPSページですが、すべてのリソースが暗号化された接続で読み込まれたとは確認できません。"
        case .localPDF: "選択したローカルPDFを表示しています。"
        case .unavailable: "現在の接続を確認できません。表示されたエラーとURLを確認してください。"
        }
    }
    var body: some View {
        Button { showingDetails.toggle() } label: {
            Label { Text(title) } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(kind == .http || kind == .mixedContent ? Color.orange : Color.secondary)
            }
        }
        .labelStyle(.titleAndIcon).font(.caption).fixedSize()
        .accessibilityIdentifier("connectionInfoButton")
        .help(explanation)
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 10) {
                Text("接続情報").font(.headline)
                Text(explanation).accessibilityIdentifier("connectionExplanation")
                if let origin = info?.origin {
                    Text("表示中のページ")
                    Text(origin).textSelection(.enabled).accessibilityIdentifier("connectionOrigin")
                }
                Button("閉じる") { showingDetails = false }
                    .accessibilityIdentifier("closeConnectionInfoButton")
            }.padding(16).frame(width: 300, alignment: .leading)
        }
    }
}
