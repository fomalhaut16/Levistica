import SwiftUI
import WebKit

struct WebPageView: NSViewRepresentable {
    let page: PageRuntime

    func makeNSView(context: Context) -> WKWebView { page.webView }

    // Rendering is not navigation. Only explicit actions call load().
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
