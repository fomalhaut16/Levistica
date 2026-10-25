import AppKit

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    private(set) weak var session: BrowserSession?
    private var openBrowserWindow: (() -> Void)?
    private var pendingURLs: [URL] = []
    private var droppedPendingURLs = false
    private var checkingTermination = false
    private var flushingHistory = false

    private var deliveryTask: Task<Void, Never>?

    func connect(session: BrowserSession, openWindow: @escaping () -> Void) {
        self.session = session
        openBrowserWindow = openWindow
        scheduleDelivery()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        let capacity = max(0, 1000 - pendingURLs.count)
        pendingURLs.append(contentsOf: urls.prefix(capacity))
        droppedPendingURLs = droppedPendingURLs || urls.count > capacity
        if session != nil {
            scheduleDelivery()
            openBrowserWindow?()
        }
    }

    private func scheduleDelivery() {
        deliveryTask?.cancel()
        deliveryTask = Task { @MainActor [weak self] in
            // Launch Services may split one multi-URL request into several events.
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.deliverPendingURLs()
        }
    }

    func deliverPendingURLs() {
        guard let session else { return }
        deliveryTask?.cancel()
        deliveryTask = nil
        let pending = pendingURLs
        pendingURLs.removeAll()
        if !pending.isEmpty { session.receiveExternalURLs(pending) }
        if droppedPendingURLs {
            session.externalOpenNotice = "受け取ったリンクが多すぎるため、一部を開きませんでした。"
            droppedPendingURLs = false
        }
        session.activateInitialSelection()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let openBrowserWindow else { return true }
        openBrowserWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !checkingTermination, !flushingHistory else { return .terminateCancel }
        checkingTermination = true
        defer { checkingTermination = false }
        if session?.isDeletingSiteData == true {
            let alert = NSAlert()
            alert.messageText = "サイトデータを削除中です"
            alert.informativeText = "完了を待ってから、もう一度終了してください。削除を途中で取り消したことにはしません。"
            alert.addButton(withTitle: "アプリに戻る")
            alert.runModal()
            return .terminateCancel
        }
        if let session, session.downloads.hasActive {
            let alert = NSAlert()
            alert.messageText = "ダウンロード中です"
            alert.informativeText = "終了すると進行中の転送を取り消します。未完了のファイルは完成品として保存しません。"
            alert.addButton(withTitle: "アプリに戻る")
            alert.addButton(withTitle: "転送を取り消して終了")
            if alert.runModal() == .alertSecondButtonReturn { session.downloads.cancelAllAndQuit() }
            return .terminateCancel
        }
        if let session, session.history.isBusy {
            flushingHistory = true
            Task { [weak self] in
                await session.history.flush()
                // Keep repeated quit requests blocked through the confirmation's
                // nested event loop and the final AppKit reply.
                defer { self?.flushingHistory = false }
                sender.reply(toApplicationShouldTerminate: Self.prepareTermination(of: session) {
                    session.confirmEditedInputForQuit()
                })
            }
            return .terminateLater
        }
        guard let session else { return .terminateNow }
        return Self.prepareTermination(of: session) {
            session.confirmEditedInputForQuit()
        } ? .terminateNow : .terminateCancel
    }

    static func prepareTermination(of session: BrowserSession, confirmInput: () -> Bool) -> Bool {
        // flush() waits for the queue observed at its call site. New work may
        // have arrived while awaiting it; never mark that session as clean.
        guard !session.history.isBusy else { return false }
        guard confirmInput() else { return false }
        // prepareToQuit rechecks pending history, transfers and deletion after
        // the confirmation's nested event loop, before saving a clean snapshot.
        return session.prepareToQuit()
    }
}
