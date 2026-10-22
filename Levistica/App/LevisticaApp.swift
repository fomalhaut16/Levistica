import SwiftUI
#if LEVISTICA_PROFILE
import Darwin
#endif

@main
struct LevisticaApp: App {
    @NSApplicationDelegateAdaptor(BrowserAppDelegate.self) private var delegate
    @State private var session = BrowserSession.applicationSession()

    var body: some Scene {
        Window("Levistica", id: "browser") {
            BrowserScene(session: session, delegate: delegate)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { BrowserCommands() }
        Settings { PrivacySettingsView(history: session.history, siteData: session.siteDataLibrary(), section: $session.settingsSection) }
    }
}

private struct BrowserScene: View {
    let session: BrowserSession
    let delegate: BrowserAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BrowserRootView(session: session)
            .focusedSceneValue(\.browserSession, session)
            .onAppear {
                let action = openWindow
                delegate.connect(session: session, openWindow: { action(id: "browser") })
            }
    }
}

private struct OpenBrowserWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ウィンドウを開く") { openWindow(id: "browser") }.keyboardShortcut("n")
    }
}

private struct BrowserSessionFocusKey: FocusedValueKey {
    typealias Value = BrowserSession
}

private extension FocusedValues {
    var browserSession: BrowserSession? {
        get { self[BrowserSessionFocusKey.self] }
        set { self[BrowserSessionFocusKey.self] = newValue }
    }
}

private struct BrowserCommands: Commands {
    @FocusedValue(\.browserSession) private var session
    #if LEVISTICA_PROFILE
    @State private var allocatorReliefSummary = "未実行"
    @State private var allocatorReliefDidRun = false
    #endif
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            OpenBrowserWindowButton()
            if let session {
                Button("PDFを開く…") { session.chooseLocalPDF() }.keyboardShortcut("o")
                Button("新しいタブ") { _ = session.newTab() }.keyboardShortcut("t")
                Button("閉じたタブを開く") { session.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!session.canReopenClosedTab)
            }
        }
        CommandGroup(replacing: .saveItem) {
            if let session {
                Button("PDFを保存…") { session.page?.savePDF() }.keyboardShortcut("s")
                    .disabled(session.page?.canSavePDF != true)
                Button("タブを閉じる") { session.closeTab(session.selectedID) }.keyboardShortcut("w")
            } else {
                Button("ウィンドウを閉じる") { NSApplication.shared.keyWindow?.performClose(nil) }.keyboardShortcut("w")
            }
        }
        #if LEVISTICA_PROFILE
        if ProcessInfo.processInfo.environment["LEVISTICA_ALLOCATOR_RELIEF"] == "1" {
            CommandMenu("診断") {
                Button("解放可能な領域を返却") {
                    guard !allocatorReliefDidRun else { return }
                    allocatorReliefDidRun = true
                    let started = DispatchTime.now().uptimeNanoseconds
                    let bytes = malloc_zone_pressure_relief(nil, 0)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - started
                    allocatorReliefSummary = "解放要求: \(bytes) bytes / \(elapsed) ns"
                }.disabled(allocatorReliefDidRun)
                Text(allocatorReliefSummary)
            }
        }
        #endif
        CommandMenu("ブックマーク") {
            if let session {
                Button("現在のページを追加") { session.addCurrentBookmark() }.keyboardShortcut("d")
                    .disabled(!session.canAddBookmark)
                Button("ブックマークを表示") { session.showBookmarks() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
            }
        }
        CommandMenu("履歴") {
            if let session {
                Button("閲覧履歴を表示") { session.showHistory() }.keyboardShortcut("y")
            }
        }
        CommandMenu("ページ") {
            if let session {
                Button("ページ内を検索") { session.showFind() }.keyboardShortcut("f")
                    .disabled(session.page == nil)
                Button("拡大") { session.page?.changeZoom(by: 1.1) }.keyboardShortcut("+")
                    .disabled(session.page == nil || (session.page?.zoom ?? 1) >= 3)
                Button("縮小") { session.page?.changeZoom(by: 1 / 1.1) }.keyboardShortcut("-")
                    .disabled(session.page == nil || (session.page?.zoom ?? 1) <= 0.5)
                Button("実際のサイズ") { session.page?.resetZoom() }.keyboardShortcut("0")
                    .disabled(session.page == nil)
                Divider()
                Button(session.activeTab.isKept ? "タブの保持を解除" : "このタブを保持") { session.toggleKeep(session.selectedID) }
                Button("このタブを休眠…") { session.requestSelectedTabSleep() }
                    .disabled(session.page == nil || session.isRequestingSleep)
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
