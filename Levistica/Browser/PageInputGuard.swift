import AppKit
import Observation
import WebKit

@MainActor @Observable
final class PageInputGuard: NSObject, WKScriptMessageHandler {
    private(set) var hasEditedInput = false
    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private let contentController: WKUserContentController
    @MainActor private final class InputRelay: NSObject, WKScriptMessageHandler {
        weak var owner: PageInputGuard?
        init(owner: PageInputGuard) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }

    private static let world = WKContentWorld.world(name: "LevisticaInputActivity")
    private static let handlerName = "levisticaInputActivity"
    private static let source = """
    (() => {
        let edited = false;
        const notify = () => window.webkit.messageHandlers.levisticaInputActivity.postMessage(true);
        const input = event => {
            if (edited || !event.isTrusted) return;
            const target = event.composedPath()[0];
            if (!(target instanceof Element)) return;
            const textControl = target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement;
            const inputControl = target instanceof HTMLInputElement && !['button','submit','reset','image','hidden'].includes(target.type);
            if (!textControl && !inputControl && !target.isContentEditable) return;
            edited = true;
            notify();
        };
        document.addEventListener('input', input, true);
        document.addEventListener('change', input, true);
        addEventListener('pageshow', () => { if (edited) notify(); });
    })();
    """

    init(configuration: WKWebViewConfiguration) {
        let controller = WKUserContentController()
        contentController = controller
        super.init()
        // Related pages may inherit the opener's controller. Own this view's
        // handler without retaining its runtime or duplicating the input script.
        for script in configuration.userContentController.userScripts where script.source != Self.source {
            controller.addUserScript(script)
        }
        controller.add(InputRelay(owner: self), contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.source, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false, in: Self.world))
        configuration.userContentController = controller
    }

    isolated deinit {
        // WebKit can retain a controller while its handler remains registered,
        // even after the WebView and weak relay owner have gone away.
        contentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
    }

    func bind(to webView: WKWebView) { self.webView = webView }
    func beginDocument() { hasEditedInput = false }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView, message.webView === webView, message.world.name == Self.world.name,
              message.name == Self.handlerName, message.body as? Bool == true,
              ["http", "https"].contains(message.frameInfo.securityOrigin.protocol) else { return }
        hasEditedInput = true
    }

    static func confirmDiscard(tabCount: Int, quitting: Bool, context: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = quitting ? "終了前に入力内容を確認してください" : "閉じる前に入力内容を確認してください"
        let label = context.map { String(decoding: $0.utf16.prefix(160), as: UTF16.self)
            .components(separatedBy: .controlCharacters).joined(separator: " ") }
        alert.informativeText = (label.map { "対象のタブ: " + $0 + "\n" } ?? "") + "入力操作のあったタブが\(tabCount)件あります。保存・送信が済んでいるか確認してください。入力内容を失ったり、添付の送信を中断したりする場合があります。"
        let keep = alert.addButton(withTitle: quitting ? "アプリに戻る" : "タブに戻る")
        let discard = alert.addButton(withTitle: quitting ? "入力を破棄して終了" : "入力を破棄して閉じる")
        discard.hasDestructiveAction = true
        // A custom cancellation title does not receive NSAlert's automatic
        // Escape shortcut. Keep Return as the safe default, and consume Escape
        // only while this alert owns the event.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.window === alert.window, event.keyCode == 53,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                keep.performClick(nil)
                return nil
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        alert.window.initialFirstResponder = keep
        alert.window.makeFirstResponder(keep)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
