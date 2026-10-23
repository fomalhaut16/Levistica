import AppKit
import WebKit

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    private(set) weak var session: BrowserSession?
    private var openBrowserWindow: (() -> Void)?
    private var pendingURLs: [URL] = []
    private var droppedPendingURLs = false
    private var checkingTermination = false
    private var flushingHistory = false

    private var deliveryTask: Task<Void, Never>?

    private var isMeasurementCleanup: Bool {
        #if LEVISTICA_MEASUREMENT
        return ProcessInfo.processInfo.environment[MeasurementWebsiteStorage.cleanupKey] != nil
        #else
        return false
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if LEVISTICA_MEASUREMENT
        guard isMeasurementCleanup else { return }
        NSApp.setActivationPolicy(.prohibited)
        let configuration: MeasurementWebsiteStorage.Configuration
        do {
            configuration = try MeasurementWebsiteStorage.configuration(
                environment: ProcessInfo.processInfo.environment, bundleIdentifier: Bundle.main.bundleIdentifier)
        } catch { preconditionFailure("Invalid isolated cleanup configuration") }
        guard let identifier = configuration.storeID, let request = configuration.cleanupRequest else {
            preconditionFailure("Cleanup requires a store and request identifier")
        }
        func finish(success: Bool, existed: Bool, unchanged: Bool) {
            let receipt: [String: Any] = ["version": 1, "storeID": identifier.uuidString,
                "requestID": request.uuidString, "success": success, "storeExisted": existed,
                "otherIdentifiersUnchanged": unchanged]
            if let data = try? JSONSerialization.data(withJSONObject: receipt, options: .sortedKeys) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            NSApp.terminate(nil)
        }
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers { identifiers in
            let before = Set(identifiers)
            guard before.contains(identifier) else {
                finish(success: true, existed: false, unchanged: true)
                return
            }
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { remaining in
                    let after = Set(remaining)
                    let unchanged = before.subtracting([identifier]) == after
                    finish(success: error == nil && !after.contains(identifier) && unchanged,
                           existed: true, unchanged: unchanged)
                }
            }
        }
        #endif
    }

    func connect(session: BrowserSession, openWindow: @escaping () -> Void) {
        guard !isMeasurementCleanup else { return }
        self.session = session
        openBrowserWindow = openWindow
        scheduleDelivery()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isMeasurementCleanup, !urls.isEmpty else { return }
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
        if isMeasurementCleanup { return .terminateNow }
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
        if session?.confirmEditedInputForQuit() == false { return .terminateCancel }
        if let session, session.history.isBusy {
            flushingHistory = true
            Task { [weak self] in
                await session.history.flush()
                self?.flushingHistory = false
                sender.reply(toApplicationShouldTerminate: session.prepareToQuit())
            }
            return .terminateLater
        }
        return session?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
}
