import Observation
import WebKit

@MainActor
@Observable
final class PageRuntime: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = "Levistica"
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var progress = 0.0
    private(set) var failure: String?
    private(set) var canRetry = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastRequest: URLRequest?
    @ObservationIgnored private var activeNavigation: WKNavigation?

    init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        // WebKit invokes KVO as values change. Hop explicitly to the UI owner;
        // do not carry the observed WKWebView across an isolation boundary.
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleSnapshot() }
        ]
    }

    nonisolated private func scheduleSnapshot() {
        Task { @MainActor [weak self] in self?.updateSnapshot() }
    }

    private func updateSnapshot() {
        if failure == nil, let current = webView.url { url = current }
        title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Levistica"
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        progress = webView.estimatedProgress
    }

    func load(_ url: URL) {
        failure = nil
        self.url = url
        lastRequest = URLRequest(url: url)
        canRetry = true
        activeNavigation = webView.load(URLRequest(url: url))
    }

    func back() { failure = nil; activeNavigation = webView.goBack() }
    func forward() { failure = nil; activeNavigation = webView.goForward() }
    func reload() {
        guard canRetry else {
            failure = "送信内容の重複を避けるため、このページは自動で再送しません。URLを入力して開き直してください。"
            return
        }
        failure = nil
        activeNavigation = webView.reload()
    }
    func stop() { webView.stopLoading() }
    func dismissFailure() { failure = nil }

    func retry() {
        // Retrying a POST could send a purchase or message twice. Never do it here.
        guard canRetry, let lastRequest else { return }
        failure = nil
        activeNavigation = webView.load(lastRequest)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame != nil else {
            failure = "別ウィンドウを開く操作は、まだ対応していません。"
            decisionHandler(.cancel)
            return
        }
        let main = action.targetFrame?.isMainFrame == true
        guard NavigationPolicy.allows(action.request.url, isMainFrame: main) else {
            if main { failure = "この種類のリンクは開けません。外部アプリの起動にはまだ対応していません。" }
            decisionHandler(.cancel)
            return
        }
        if main {
            lastRequest = action.request
            canRetry = action.request.httpMethod == "GET"
            url = action.request.url
            failure = nil
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard response.canShowMIMEType else {
            failure = "このファイルのダウンロードには、まだ対応していません。"
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
        failure = nil
        updateSnapshot()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateSnapshot() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateSnapshot() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { navigationFailed(navigation, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) { navigationFailed(navigation, error: error) }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        guard navigation === activeNavigation else { return }
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        updateSnapshot()
        url = lastRequest?.url ?? url
        failure = error.domain == NSURLErrorDomain && (-1206 ... -1200).contains(error.code)
            ? "安全な接続を確認できませんでした。証明書の検証は省略しません。"
            : "ページを読み込めませんでした。接続とURLを確認してください。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        updateSnapshot()
        failure = "ページの処理が終了しました。再試行すると、入力内容などが失われる場合があります。"
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        failure = "カメラとマイクの使用には、まだ対応していません。"
        decisionHandler(.deny)
    }
}
