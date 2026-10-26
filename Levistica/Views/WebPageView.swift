import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let pages: [PageRuntime]
    let selectedPage: PageRuntime?

    func makeNSView(context: Context) -> WebPageContainer {
        let container = WebPageContainer(frame: .zero)
        container.display(pages.map(\.webView), selected: selectedPage?.webView)
        return container
    }

    func updateNSView(_ nsView: WebPageContainer, context: Context) {
        nsView.display(pages.map(\.webView), selected: selectedPage?.webView)
    }
}

@MainActor
final class WebPageContainer: NSView {
    private var managedViews: [WKWebView] = []
    private weak var selectedView: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Preserve inactive viewport sizes. A WebKit fullscreen owner can still
        // use the WebView's autoresizing mask after temporarily reparenting it.
        autoresizesSubviews = false
    }

    required init?(coder: NSCoder) { nil }

    func display(_ views: [WKWebView], selected: WKWebView?) {
        let nextSelected = selected.flatMap { candidate in views.contains { $0 === candidate } ? candidate : nil }
        let transferPageFocus = managedViews.contains { view in
            guard view !== nextSelected, view.superview === self,
                  let responder = window?.firstResponder as? NSView else { return false }
            return responder === view || responder.isDescendant(of: view)
        }
        let wanted = Set(views.map(ObjectIdentifier.init))
        for view in managedViews where !wanted.contains(ObjectIdentifier(view)) {
            if view.superview === self { view.removeFromSuperview() }
        }
        managedViews = views
        selectedView = nextSelected
        for view in views {
            if view.superview == nil || (view.superview is WebPageContainer && view.superview !== self) {
                view.autoresizingMask = [.width, .height]
                addSubview(view)
            }
            // Do not steal or resize a WebKit-owned fullscreen view.
            if view.superview === self { view.isHidden = view !== selectedView }
        }
        layout()
        if transferPageFocus, let window {
            if let selectedView, selectedView.superview === self, window.makeFirstResponder(selectedView) { return }
            window.makeFirstResponder(nil)
        }
    }

    override func layout() {
        super.layout()
        if let view = selectedView, view.superview === self { view.frame = bounds }
    }
}
