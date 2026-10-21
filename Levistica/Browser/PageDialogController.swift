import AppKit
import Observation

@MainActor @Observable
final class PageDialogController {
    var notice: String?
    @ObservationIgnored private var activeAlert: NSAlert?
    @ObservationIgnored private var pendingCompletion: ((Bool, String?) -> Void)?
    @ObservationIgnored private var departureEscapeMonitor: Any?
    private var presentedCount = 0
    private var suppressed = false

    func confirmDeparture(window: NSWindow?, completion: @escaping @MainActor (Bool) -> Void) {
        confirmBrowserAction(window: window, title: "ページを離れる前に入力内容を確認してください",
                             message: "入力操作がありました。再読み込みやページの移動で、入力内容や添付の選択を失う場合があります。保存・送信が済んでいるか確認してください。",
                             action: "入力を破棄して移動", completion: completion)
    }

    func confirmSleep(window: NSWindow?, completion: @escaping @MainActor (Bool) -> Void) {
        confirmBrowserAction(window: window, title: "このタブを休眠しますか？",
                             message: "ページを解放し、再開時にURLから読み込み直します。入力、ページ内の戻る履歴、スクロール、再生位置、通話や接続の状態は復元されません。独自の入力欄や通信は検知できない場合があります。保存・送信と接続の終了を確認してください。",
                             action: "状態を破棄して休眠", completion: completion)
    }

    private func confirmBrowserAction(window: NSWindow?, title: String, message: String, action: String,
                                      completion: @escaping @MainActor (Bool) -> Void) {
        // Browser-owned protection is independent of a site's dialog allowance.
        guard activeAlert == nil, let window, window.isKeyWindow, window.attachedSheet == nil else {
            notice = "操作を取り消しました。このタブを選び、ほかの確認画面を閉じてから操作してください。"
            completion(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let keep = alert.addButton(withTitle: "ページに戻る")
        let leave = alert.addButton(withTitle: action)
        leave.hasDestructiveAction = true
        alert.window.defaultButtonCell = keep.cell as? NSButtonCell
        alert.window.preventsApplicationTerminationWhenModal = false
        activeAlert = alert
        pendingCompletion = { allowed, _ in completion(allowed) }
        departureEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak alert, weak keep] event in
            if let alert, event.window === alert.window, event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                keep?.performClick(nil)
                return nil
            }
            return event
        }
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.activeAlert === alert else { return }
            let handler = self.pendingCompletion
            self.pendingCompletion = nil
            self.activeAlert = nil
            self.removeDepartureMonitor()
            handler?(response == .alertSecondButtonReturn, nil)
        }
    }

    func present(message: String, origin: String, window: NSWindow?, allowsCancel: Bool,
                 promptDefault: String? = nil, isPrompt: Bool = false,
                 completion: @escaping @MainActor (Bool, String?) -> Void) {
        guard !suppressed, presentedCount < 5 else {
            notice = "このページのダイアログを停止しています。再読み込みすると再び表示できます。"
            completion(false, nil)
            return
        }
        guard activeAlert == nil, let window, window.isKeyWindow, window.attachedSheet == nil else {
            notice = "背面タブや、ほかの確認画面が開いている間は、サイトのダイアログを表示しません。必要ならこのタブを選び、サイトでもう一度操作してください。"
            completion(false, nil)
            return
        }
        presentedCount += 1
        let alert = NSAlert()
        alert.messageText = "Webサイトからのメッセージ\n" + origin
        let truncated = message.utf16.prefix(4097).count > 4096 || (promptDefault?.utf16.prefix(4097).count ?? 0) > 4096
        let body = Self.boundedText(message)
        let scrollable = body.utf16.count > 256 || body.components(separatedBy: .newlines).count > 6
        alert.informativeText = (scrollable ? "長いメッセージです。下の欄をスクロールして確認できます。" : body)
            + (truncated ? "\n長いメッセージや初期値は一部を省略しています。" : "")
        alert.addButton(withTitle: "OK")
        if allowsCancel { alert.addButton(withTitle: "キャンセル") }
        let stopButton = alert.addButton(withTitle: "このページのダイアログを停止")
        var field: NSTextField?
        if isPrompt {
            let input = NSTextField(string: Self.boundedText(promptDefault ?? ""))
            input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            input.setAccessibilityIdentifier("sitePromptInput")
            input.setAccessibilityLabel("サイトに返す入力")
            alert.accessoryView = input
            field = input
        }
        if scrollable { alert.accessoryView = Self.scrollingMessage(body, input: field) }
        alert.window.preventsApplicationTerminationWhenModal = false
        activeAlert = alert
        pendingCompletion = completion
        alert.beginSheetModal(for: window) { [weak self, weak alert] response in
            guard let self, let alert, self.activeAlert === alert else { return }
            // An alert without Cancel has the Stop button in the second position.
            let stopped = alert.buttons.firstIndex(of: stopButton).map {
                response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + $0
            } ?? false
            if stopped {
                self.suppressed = true
                self.notice = "このページのダイアログを停止しています。再読み込みすると再び表示できます。"
            }
            let handler = self.pendingCompletion
            self.pendingCompletion = nil
            self.activeAlert = nil
            handler?(response == .alertFirstButtonReturn, field?.stringValue)
        }
        if let field { alert.window.makeFirstResponder(field) }
        else if scrollable { alert.window.makeFirstResponder(alert.buttons.first) }
    }

    private static func scrollingMessage(_ text: String, input: NSTextField?) -> NSView {
        let messageHeight: CGFloat = 180
        let inputHeight: CGFloat = input == nil ? 0 : 32
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: messageHeight + inputHeight))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: inputHeight, width: 360, height: messageHeight))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.setAccessibilityIdentifier("siteDialogMessageScroll")
        let content = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        content.isEditable = false
        content.isSelectable = true
        content.isRichText = false
        content.isVerticallyResizable = true
        content.isHorizontallyResizable = false
        content.autoresizingMask = [.width]
        content.minSize = .zero
        content.maxSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        content.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        content.textContainer?.widthTracksTextView = true
        content.textContainerInset = NSSize(width: 6, height: 6)
        content.font = .systemFont(ofSize: NSFont.systemFontSize)
        content.string = text
        content.setAccessibilityLabel("サイトのメッセージ本文")
        scroll.documentView = content
        content.sizeToFit()
        container.addSubview(scroll)
        if let input {
            input.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
            container.addSubview(input)
        }
        return container
    }

    static func boundedText(_ value: String) -> String {
        String(decoding: value.utf16.prefix(4096), as: UTF16.self)
    }

    func cancel() {
        guard let alert = activeAlert else { return }
        removeDepartureMonitor()
        let handler = pendingCompletion
        pendingCompletion = nil
        activeAlert = nil
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
        alert.window.orderOut(nil)
        handler?(false, nil)
    }

    private func removeDepartureMonitor() {
        if let departureEscapeMonitor { NSEvent.removeMonitor(departureEscapeMonitor) }
        departureEscapeMonitor = nil
    }

    func beginDocument() {
        cancel()
        presentedCount = 0
        suppressed = false
        notice = nil
    }
}
