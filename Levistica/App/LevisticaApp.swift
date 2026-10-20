import SwiftUI

@main
struct LevisticaApp: App {
    @State private var session = BrowserSession()

    var body: some Scene {
        Window("Levistica", id: "browser") {
            BrowserRootView(session: session)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                OpenBrowserWindowButton()
            }
            CommandMenu("ページ") {
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
