import AppKit
import Observation
import WebKit

@MainActor @Observable
final class PageInputGuard: NSObject, WKScriptMessageHandler {
    private var activity = PageInputActivityState()
    var hasEditedInput: Bool { activity.hasEditedInput }
    var needsDepartureConfirmation: Bool { activity.needsDepartureConfirmation }
    func approveDeparture() { activity.approveDeparture() }
    func cancelDepartureApproval() { activity.cancelDepartureApproval() }
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
    static let source = """
    (() => {
        const frame = String(Date.now()) + '-' + Math.random().toString(36).slice(2);
        let revision = 0;
        const originals = new WeakMap();
        const changed = new Set();
        const control = event => {
            const target = event.composedPath()[0];
            if (!(target instanceof Element)) return null;
            if (target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement) return target;
            if (target instanceof HTMLInputElement && !['button','submit','reset','image','hidden'].includes(target.type)) return target;
            if (!target.isContentEditable) return null;
            let editable = target;
            while (editable.parentElement?.isContentEditable) editable = editable.parentElement;
            return editable;
        };
        const value = target => {
            if (target instanceof HTMLInputElement && ['checkbox','radio'].includes(target.type)) return target.checked;
            if (target instanceof HTMLInputElement && target.type === 'file') return target.files.length > 0;
            if (target instanceof HTMLSelectElement) return JSON.stringify([...target.options].map(option => option.selected));
            return target.isContentEditable ? target.innerHTML : target.value;
        };
        const remember = target => {
            if (!originals.has(target)) originals.set(target, value(target));
        };
        const search = target => target.type === 'search' || target.getAttribute('role') === 'searchbox'
            || target.closest('search, [role="search"]') !== null;
        const notify = () => {
            for (const target of changed) {
                if (!target.isConnected || value(target) === originals.get(target)) changed.delete(target);
            }
            window.webkit.messageHandlers.levisticaInputActivity.postMessage({frame, revision, pending: changed.size > 0});
        };
        for (const type of ['focusin', 'beforeinput']) document.addEventListener(type, event => {
            if (!event.isTrusted) return;
            const target = control(event);
            if (target) remember(target);
        }, true);
        const input = event => {
            if (!event.isTrusted) return;
            const target = control(event);
            if (!target) return;
            // focusin/beforeinput record the pre-edit value. A control edited
            // without either event remains conservatively pending.
            revision += 1;
            if (!search(target) && (!originals.has(target) || value(target) !== originals.get(target))) changed.add(target);
            else changed.delete(target);
            notify();
        };
        document.addEventListener('input', input, true);
        document.addEventListener('change', input, true);
        document.addEventListener('submit', event => {
            if (!event.isTrusted) return;
            // A successful native form submission is an explicit send action.
            // A prevented SPA submission may still contain an unsaved draft.
            queueMicrotask(() => {
                if (event.defaultPrevented) return;
                for (const target of changed) if (target.form === event.target) {
                    originals.set(target, value(target)); changed.delete(target);
                }
                notify();
            });
        }, true);
        document.addEventListener('reset', event => queueMicrotask(() => {
            if (event.isTrusted && !event.defaultPrevented) notify();
        }), true);
        addEventListener('pageshow', event => { if (event.isTrusted) notify(); });
        addEventListener('pagehide', event => {
            if (event.isTrusted) window.webkit.messageHandlers.levisticaInputActivity.postMessage({frame, revision, pending: false});
        });
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
    func beginDocument() { activity = PageInputActivityState() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView, message.webView === webView, message.world.name == Self.world.name,
              message.name == Self.handlerName,
              ["http", "https"].contains(message.frameInfo.securityOrigin.protocol) else { return }
        guard let body = message.body as? [String: Any], let frame = body["frame"] as? String,
              let revision = body["revision"] as? Int, let pending = body["pending"] as? Bool else { return }
        activity.receive(frame: frame, revision: revision, pending: pending)
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

// Input activity protects close/sleep conservatively. Navigation warnings use
// pending edits; accepting one departure covers delegate re-entry until a new
// trusted edit, commit, cancellation, or failed navigation.
struct PageInputActivityState {
    private(set) var hasEditedInput = false
    private var frames: [String: (revision: Int, pending: Bool)] = [:]
    private var approved = false
    private var overflowPending = false
    var needsDepartureConfirmation: Bool { !approved && (overflowPending || frames.values.contains { $0.pending }) }

    mutating func receive(frame: String, revision: Int, pending: Bool) {
        guard !frame.isEmpty, frame.utf8.count <= 64, revision >= 0, !pending || revision > 0 else { return }
        if let prior = frames[frame], revision < prior.revision { return }
        if revision > 0 { hasEditedInput = true }
        if frames[frame] == nil && frames.count >= 128 {
            if pending { overflowPending = true; approved = false }
            return
        }
        if revision > (frames[frame]?.revision ?? 0) { approved = false }
        frames[frame] = (revision, pending)
    }
    mutating func approveDeparture() { approved = true }
    mutating func cancelDepartureApproval() { approved = false }
}
