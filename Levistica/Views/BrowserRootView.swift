import SwiftUI

struct BrowserRootView: View {
    @Bindable var session: BrowserSession

    var body: some View {
        HSplitView {
            TabSidebar(session: session)
            tabContent(session.activeTab)
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 420)
    }

    private func tabContent(_ tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            BrowserNavigationBar(session: session, tab: tab).id(tab.id)
            if let origin = tab.openerOrigin {
                Text("別タブの要求元: \(origin)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4)
                    .accessibilityIdentifier("pageOpenerOrigin")
            }
            if let message = session.storageFailure {
                HStack {
                    Text(message).accessibilityIdentifier("storageFailure")
                    Spacer()
                    Button("保存を再試行") { session.persistSession() }
                    Button("保存せず終了") {
                        session.discardUnsavedChangesOnQuit = true
                        NSApplication.shared.terminate(nil)
                    }
                }.padding(8)
            }
            if session.recoveryRequired {
                HStack {
                    Text("前回は正常に終了しませんでした。タブ一覧だけを復元しました。")
                        .accessibilityIdentifier("sessionRecoveryNotice")
                    Spacer()
                    Button("選択中のページを開く") { session.resumeSelectedTab() }
                }.padding(8)
            }
            if let message = tab.inputError ?? tab.page?.failure {
                HStack {
                    Text(message).textSelection(.enabled).accessibilityIdentifier("errorMessage")
                    Spacer()
                    if tab.inputError == nil && tab.page?.canRetry == true {
                        Button("再試行") { tab.page?.retry() }
                    }
                    Button("閉じる") { tab.inputError = nil; tab.page?.dismissFailure() }
                }
                .padding(10).background(.regularMaterial)
            }
            if let notice = tab.restorationNotice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("閉じる") { tab.restorationNotice = nil }
                }.padding(8)
            }
            if let page = tab.page, tab.isFindBarVisible {
                PageFindBar(session: session, tab: tab, page: page).id(tab.id)
            }
            Divider()
            if let page = tab.page {
                // Each runtime supplies its own existing NSView; rendering never starts a load.
                WebPageView(page: page).id(tab.id).accessibilityIdentifier("pageView")
                    .overlay(alignment: .top) {
                        if page.isLoading {
                            ProgressView(value: page.progress).progressViewStyle(.linear)
                        }
                    }
            } else {
                ContentUnavailableView("Levistica", systemImage: "globe",
                                       description: Text("URLを入力してページを開きます。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
