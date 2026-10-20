import SwiftUI

@main
struct LevisticaApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate
    @State private var session = BrowserSession.applicationSession()

    var body: some Scene {
        Window("Levistica", id: "browser") {
            BrowserRootView(session: session)
                .onAppear {
                    delegate.session = session
                    session.activateInitialSelection()
                }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenBrowserWindowButton()
                Button("新しいタブ") { _ = session.newTab() }.keyboardShortcut("t")
                Button("閉じたタブを開く") { session.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!session.canReopenClosedTab)
            }
            CommandGroup(replacing: .saveItem) {
                Button("タブを閉じる") { session.closeTab(session.selectedID) }.keyboardShortcut("w")
            }
            CommandMenu("ページ") {
                Button("ページ内を検索") { session.showFind() }.keyboardShortcut("f")
                    .disabled(session.page == nil)
                Button("拡大") { session.page?.changeZoom(by: 1.1) }.keyboardShortcut("+")
                    .disabled(session.page == nil || (session.page?.zoom ?? 1) >= 3)
                Button("縮小") { session.page?.changeZoom(by: 1 / 1.1) }.keyboardShortcut("-")
                    .disabled(session.page == nil || (session.page?.zoom ?? 1) <= 0.5)
                Button("実際のサイズ") { session.page?.resetZoom() }.keyboardShortcut("0")
                    .disabled(session.page == nil)
                Divider()
                Button("次のタブ") { session.selectAdjacent(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("前のタブ") { session.selectAdjacent(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("URLを入力") { session.addressFocusRequest += 1 }.keyboardShortcut("l")
                Button("戻る") { session.page?.back() }
                    .keyboardShortcut("[").disabled(session.page?.canGoBack != true)
                Button("進む") { session.page?.forward() }
                    .keyboardShortcut("]").disabled(session.page?.canGoForward != true)
                Button("再読み込み") { session.page?.reload() }
                    .keyboardShortcut("r").disabled(session.page == nil)
                Button("読み込みを停止") { session.page?.stop() }
                    .keyboardShortcut(".").disabled(session.page?.isLoading != true)
            }
        }
    }
}

private struct OpenBrowserWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ウィンドウを開く") { openWindow(id: "browser") }.keyboardShortcut("n")
    }
}
