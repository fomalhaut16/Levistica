import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let page: PageRuntime

    func makeNSView(context: Context) -> WebPageContainer { WebPageContainer(webView: page.webView) }

    // SwiftUI sizes the stable container. WebKit can temporarily reparent its own view
    // for element fullscreen without SwiftUI imposing the original content frame.
    func updateNSView(_ nsView: WebPageContainer, context: Context) {}
}

@MainActor
final class WebPageContainer: NSView {
    let webView: WKWebView

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Never resize a WebKit-owned fullscreen view from the background window.
        if webView.superview === self { webView.frame = bounds }
    }
}
