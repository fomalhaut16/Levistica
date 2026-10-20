import AppKit

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: BrowserSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let session, session.downloads.hasActive {
            let alert = NSAlert()
            alert.messageText = "ダウンロード中です"
            alert.informativeText = "終了すると進行中の転送を取り消します。未完了のファイルは完成品として保存しません。"
            alert.addButton(withTitle: "アプリに戻る")
            alert.addButton(withTitle: "転送を取り消して終了")
            if alert.runModal() == .alertSecondButtonReturn { session.downloads.cancelAllAndQuit() }
            return .terminateCancel
        }
        return session?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
}
