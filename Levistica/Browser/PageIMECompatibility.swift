import WebKit

enum PageIMECompatibility {
    // WebKit bug 165004: legacy macOS ordering emits the IME confirmation after
    // compositionend with isComposing=false, but retains the process-key code.
    // Do not cancel default editing, change event properties, or inspect text.
    static let source = """
    (() => {
        const confirmations = new Set();
        const identity = event => event.code || String(event.location);
        window.addEventListener('keydown', event => {
            if (!event.isTrusted || event.key !== 'Enter') return;
            const key = identity(event);
            if (event.keyCode === 229 && !event.isComposing) {
                confirmations.add(key);
                event.stopImmediatePropagation();
            } else {
                // A new ordinary press cannot inherit an unmatched prior keyup.
                confirmations.delete(key);
            }
        }, true);
        for (const type of ['keypress', 'keyup']) {
            window.addEventListener(type, event => {
                if (!event.isTrusted || event.key !== 'Enter') return;
                const key = identity(event);
                if (!confirmations.has(key)) return;
                event.stopImmediatePropagation();
                if (type === 'keyup') confirmations.delete(key);
            }, true);
        }
        window.addEventListener('blur', () => confirmations.clear());
    })();
    """

    @MainActor static func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source == source }) else { return }
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: .world(name: "LevisticaIMECompatibility")))
    }
}
