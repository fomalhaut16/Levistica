import Observation
import WebKit

@MainActor
@Observable
final class PageRuntime: NSObject, WKNavigationDelegate, WKUIDelegate {
    let inputGuard: PageInputGuard
    let dialogs = PageDialogController()
    let localPDF: LocalPDF?
    let webView: WKWebView
    var onMetadataChange: (() -> Void)?
    var onVisit: ((URL, String, Date) -> Void)?
    var onVisitTitle: ((URL, String, Date) -> Void)?
    @ObservationIgnored private var lastHistoryVisit: (url: URL, time: Date)?
    var onCreatePage: ((WKWebViewConfiguration, String, Bool) -> WKWebView?)?
    var onOpenLink: ((URLRequest, Bool, String) -> Void)?
    var onClose: (() -> Void)?
    var onDownload: ((WKDownload) -> Void)?
    @ObservationIgnored private var filePanel: NSOpenPanel?
    private var permitsInitialBlankPage: Bool
    private var recentPageCreations: [TimeInterval] = []
    private(set) var url: URL?
    private(set) var title = "Levistica"
    private(set) var isPDF = false
    private var pendingPDFTitle: String?
    private var pdfTitle: String?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var progress = 0.0
    var findQuery = ""
    private(set) var findMatchFound: Bool?
    private(set) var zoom = 1.0
    @ObservationIgnored private var findGeneration = 0
    private(set) var failure: String?
    private(set) var canRetry = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastRequest: URLRequest?
    @ObservationIgnored private var committedRequest: URLRequest?
    @ObservationIgnored private var committedURL: URL?
    @ObservationIgnored private var committedUserAgent: String?
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private var documentGeneration = 0
    var documentRevision: Int { documentGeneration }
    #if DEBUG || LEVISTICA_MEASUREMENT
    @ObservationIgnored let measurementInstanceID = UUID()
    #endif
    var isChoosingFile: Bool { filePanel != nil }

    convenience init(dataStore: WKWebsiteDataStore = .default()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        self.init(configuration: configuration)
    }

    init(configuration: WKWebViewConfiguration, permitsInitialBlankPage: Bool = false, localPDF: LocalPDF? = nil) {
        self.localPDF = localPDF
        configuration.applicationNameForUserAgent = WebKitBrowserIdentity.applicationName
        if localPDF != nil { configuration.defaultWebpagePreferences.allowsContentJavaScript = false }
        self.permitsInitialBlankPage = permitsInitialBlankPage
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = true
        inputGuard = PageInputGuard(configuration: configuration)
        PageIMECompatibility.install(in: configuration.userContentController)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        inputGuard.bind(to: webView)
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
        let previousURL = url
        let previousTitle = title
        // A provisional URL can survive briefly after a navigation becomes a
        // download. Only committed history locations may replace the page URL.
        if failure == nil, !webView.isLoading, let current = webView.url,
           current.absoluteString != "about:blank", webView.backForwardList.currentItem?.url == current { url = current }
        title = localPDF?.url.lastPathComponent ?? (isPDF ? pdfTitle : nil)
            ?? webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Levistica"
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        progress = webView.estimatedProgress
        if previousURL != url || previousTitle != title { onMetadataChange?() }
        // A completed document may change its URL without a new navigation.
        // Require a committed GET and the current history item, so provisional
        // destinations, POST documents and failed loads do not become visits.
        if let visit = lastHistoryVisit, let current = webView.url,
           current != visit.url, !isLoading, failure == nil, localPDF == nil,
           committedRequest?.httpMethod == "GET", canRetry,
           webView.backForwardList.currentItem?.url == current,
           current.scheme == visit.url.scheme, current.host == visit.url.host,
           current.port == visit.url.port, SessionStore.persistableURL(current) == current {
            let visited = Date()
            lastHistoryVisit = (current, visited)
            onVisit?(current, title, visited)
        }
        if previousTitle != title, let visit = lastHistoryVisit, visit.url == url {
            onVisitTitle?(visit.url, title, visit.time)
        }
    }

    func invalidateFindResult() {
        findGeneration += 1
        findMatchFound = nil
    }

    func findNext(backwards: Bool = false) {
        invalidateFindResult()
        guard !findQuery.isEmpty else { return }
        let generation = findGeneration
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(findQuery, configuration: configuration) { [weak self] result in
            guard let self, self.findGeneration == generation else { return }
            self.findMatchFound = result.matchFound
        }
    }

    func clearFind() {
        findQuery = ""
        invalidateFindResult()
        webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    func changeZoom(by factor: Double) {
        zoom = min(3, max(0.5, (zoom * factor * 100).rounded() / 100))
        webView.pageZoom = zoom
    }

    func resetZoom() {
        zoom = 1
        webView.pageZoom = 1
    }

    var canSavePDF: Bool {
        isPDF && localPDF == nil && !isLoading && canRetry && NavigationPolicy.allows(url, isMainFrame: true)
    }

    func savePDF() {
        guard canSavePDF, let url else { return }
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in
            guard let onDownload = self?.onDownload else { download.cancel { _ in }; return }
            onDownload(download)
        }
    }

    func loadLocalPDF() {
        guard let localPDF else { return }
        invalidateFindResult()
        failure = nil
        url = localPDF.url
        lastRequest = URLRequest(url: localPDF.url)
        canRetry = true
        activeNavigation = webView.loadFileURL(localPDF.url, allowingReadAccessTo: localPDF.url)
        if activeNavigation == nil { failure = "PDFの読み込みを開始できませんでした。ファイルを選び直してください。" }
    }

    func load(_ url: URL) {
        load(URLRequest(url: url))
    }

    func load(_ request: URLRequest) {
        // WKNavigationType.other also covers a page's own JavaScript navigation.
        // Confirm browser-owned loads here, before they become indistinguishable
        // from a successful login's location change in the navigation delegate.
        guard committedRequest != nil, inputGuard.hasEditedInput else {
            beginLoad(request)
            return
        }
        let generation = documentGeneration
        dialogs.confirmDeparture(window: webView.window) { [weak self] allowed in
            guard let self, self.documentGeneration == generation else { return }
            guard allowed else { self.restoreCommittedLocation(); return }
            self.beginLoad(request)
        }
    }

    private func beginLoad(_ request: URLRequest) {
        invalidateFindResult()
        failure = nil
        // Keep the committed page as the session/URL source while an edited
        // document's navigation is awaiting permission. Initial loads still
        // expose their destination before WebKit has allocated a document.
        if committedRequest == nil || !inputGuard.hasEditedInput {
            url = request.url
            lastRequest = request
            canRetry = request.httpMethod == "GET"
        }
        activeNavigation = webView.load(request)
        if activeNavigation == nil {
            failure = "このURLの読み込みを開始できませんでした。URLと接続先を確認してください。"
        }
    }

    func back() { failure = nil; activeNavigation = webView.goBack() }
    func forward() { failure = nil; activeNavigation = webView.goForward() }
    func reload() {
        if localPDF != nil { loadLocalPDF(); return }
        guard canRetry else {
            failure = "送信内容の重複を避けるため、このページは自動で再送しません。URLを入力して開き直してください。"
            return
        }
        failure = nil
        activeNavigation = webView.reload()
    }
    func stop() {
        dialogs.cancel()
        webView.stopLoading()
        restoreDisplayedIdentity()
    }

    private func restoreDisplayedIdentity() {
        // A provisional destination has not replaced the committed document.
        webView.customUserAgent = committedUserAgent
    }
    func dismissFailure() { failure = nil }

    func retry() {
        if localPDF != nil { loadLocalPDF(); return }
        // Retrying a POST could send a purchase or message twice. Never do it here.
        guard canRetry, let lastRequest else { return }
        load(lastRequest)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if let localPDF {
            let main = action.targetFrame?.isMainFrame == true
            if action.navigationType == .linkActivated, action.request.httpMethod == "GET",
               let link = action.request.url, NavigationPolicy.allows(link, isMainFrame: true) {
                let background = (action.modifierFlags.contains(.command) || action.buttonNumber == 2)
                    && !action.modifierFlags.contains(.shift)
                // Do not forward a local path as a referrer or reuse PDF-only settings.
                onOpenLink?(URLRequest(url: link), !background, "ローカルPDF")
                decisionHandler(.cancel)
                return
            }
            let selectedFile = main && localPDF.allows(action.request.url) && action.request.httpMethod == "GET"
            let embedded = action.targetFrame != nil && !main && ["about", "blob", "data"].contains(action.request.url?.scheme)
            guard selectedFile || embedded else {
                failure = "このPDFからそのリンクは開けません。別のローカルファイルは選び直してください。"
                decisionHandler(.cancel)
                return
            }
            if main { lastRequest = action.request; url = action.request.url; canRetry = true }
            decisionHandler(.allow)
            return
        }
        if action.targetFrame == nil {
            let allowed = NavigationPolicy.allowsNewContext(action.request.url)
            if !allowed { failure = "この種類のリンクは別タブに開けません。" }
            decisionHandler(allowed ? .allow : .cancel)
            return
        }
        let main = action.targetFrame?.isMainFrame == true
        if action.shouldPerformDownload && action.request.url?.scheme == "blob" {
            decisionHandler(.download)
            return
        }
        let initialBlank = main && permitsInitialBlankPage && NavigationPolicy.isBlankContextURL(action.request.url)
        guard initialBlank || NavigationPolicy.allows(action.request.url, isMainFrame: main) else {
            if main { failure = "この種類のリンクは開けません。外部アプリの起動にはまだ対応していません。" }
            decisionHandler(.cancel)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if action.navigationType == .linkActivated && action.request.httpMethod == "GET",
           NavigationPolicy.allows(action.request.url, isMainFrame: true),
           action.modifierFlags.contains(.command) || action.buttonNumber == 2,
           let onOpenLink {
            onOpenLink(action.request, action.modifierFlags.contains(.shift), Self.origin(of: action.sourceFrame))
            decisionHandler(.cancel)
            return
        }
        if main, inputGuard.hasEditedInput,
           Self.requiresDepartureConfirmation(type: action.navigationType, current: webView.url, destination: action.request.url) {
            let generation = documentGeneration
            dialogs.confirmDeparture(window: webView.window) { [weak self] allowed in
                guard let self else { decisionHandler(.cancel); return }
                guard allowed, self.documentGeneration == generation else {
                    if self.documentGeneration == generation { self.restoreCommittedLocation() }
                    decisionHandler(.cancel)
                    return
                }
                self.acceptMainNavigation(action.request, initialBlank: initialBlank)
                decisionHandler(.allow)
            }
            return
        }
        if main { acceptMainNavigation(action.request, initialBlank: initialBlank) }
        decisionHandler(.allow)
    }

    static func requiresDepartureConfirmation(type: WKNavigationType, current: URL?, destination: URL?) -> Bool {
        // Submitting a form is the explicit send action, not an abandoned draft.
        if type == .formSubmitted || type == .formResubmitted || type == .other { return false }
        if type == .linkActivated,
           let current, let destination, current != destination,
           var from = URLComponents(url: current, resolvingAgainstBaseURL: false),
           var to = URLComponents(url: destination, resolvingAgainstBaseURL: false) {
            from.fragment = nil
            to.fragment = nil
            if from == to { return false }
        }
        return true
    }

    private func restoreCommittedLocation() {
        url = displayedDocumentURL
        lastRequest = committedRequest
        canRetry = committedRequest?.httpMethod == "GET"
        onMetadataChange?()
    }

    private func acceptMainNavigation(_ request: URLRequest, initialBlank: Bool) {
        webView.customUserAgent = NavigationPolicy.userAgent(for: request.url)
        if !initialBlank { permitsInitialBlankPage = false }
        lastRequest = request
        canRetry = request.httpMethod == "GET"
        url = request.url
        failure = nil
        onMetadataChange?()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard NavigationPolicy.allowsNewContext(action.request.url) else {
            failure = "この種類のリンクは別タブに開けません。"
            return nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        recentPageCreations.removeAll { now - $0 >= 1 }
        guard recentPageCreations.count < 5 else {
            failure = "短時間に多くの別タブを開く要求があったため、追加を止めました。"
            return nil
        }
        recentPageCreations.append(now)
        // WebKit loads the original request, including POST bodies, exactly once.
        // Do not replace its related configuration or manually replay the request.
        let background = (action.modifierFlags.contains(.command) || action.buttonNumber == 2)
            && !action.modifierFlags.contains(.shift)
        return onCreatePage?(configuration, Self.origin(of: action.sourceFrame), !background)
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    private static func origin(of frame: WKFrameInfo) -> String {
        let origin = frame.securityOrigin
        guard ["http", "https"].contains(origin.protocol), !origin.host.isEmpty else { return "不明な要求元" }
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port > 0 { components.port = origin.port }
        return components.string ?? "不明な要求元"
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        let download = !response.canShowMIMEType || disposition == "attachment"
        if response.isForMainFrame && !download {
            // Reconcile the final destination after server redirects as well.
            webView.customUserAgent = NavigationPolicy.userAgent(for: response.response.url)
            pendingPDFTitle = nil
            if response.response.mimeType?.lowercased() == "application/pdf" {
                let name = response.response.suggestedFilename ?? "PDF資料"
                pendingPDFTitle = String(decoding: name.utf16.prefix(512), as: UTF16.self).components(separatedBy: .controlCharacters).joined(separator: " ")
            }
        }
        decisionHandler(download ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        acceptDownload(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        acceptDownload(download)
    }

    private func acceptDownload(_ download: WKDownload) {
        // A download did not replace the displayed document. Preserve its POST guard
        // and never persist the download URL as a page to reopen on the next launch.
        restoreDisplayedIdentity()
        lastRequest = committedRequest
        canRetry = committedRequest?.httpMethod == "GET"
        url = displayedDocumentURL
        isLoading = false
        failure = nil
        onMetadataChange?()
        if let onDownload { onDownload(download) } else { download.cancel { _ in } }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        dialogs.present(message: message, origin: Self.origin(of: frame), window: webView.window,
                        allowsCancel: false) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        dialogs.present(message: message, origin: Self.origin(of: frame), window: webView.window,
                        allowsCancel: true) { accepted, _ in completionHandler(accepted) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor (String?) -> Void) {
        dialogs.present(message: prompt, origin: Self.origin(of: frame), window: webView.window,
                        allowsCancel: true, promptDefault: defaultText, isPrompt: true) { accepted, text in
            completionHandler(accepted ? text : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard filePanel == nil, let window = webView.window,
              window.isKeyWindow, window.attachedSheet == nil else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        filePanel = panel
        panel.title = parameters.allowsDirectories ? "サイトへ渡すフォルダを選択" : "サイトへ渡すファイルを選択"
        panel.prompt = "選択"
        if let directory = FilePanelDefaults.testDirectory { panel.directoryURL = directory }
        panel.message = "要求元: " + Self.origin(of: frame)
            + (parameters.allowsDirectories ? "\n選択したフォルダ内のファイルもサイトへ渡します。" : "")
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = !parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { [weak self] result in
            self?.filePanel = nil
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func cancelFileSelection() { filePanel?.cancel(nil) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
        lastHistoryVisit = nil
        pendingPDFTitle = nil
        failure = nil
        updateSnapshot()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateSnapshot()
        if let navigation, let activeNavigation, navigation !== activeNavigation { return }
        guard localPDF == nil, failure == nil, canRetry, let url = webView.url,
              SessionStore.persistableURL(url) == url else { return }
        let visited = Date()
        lastHistoryVisit = (url, visited)
        onVisit?(url, title, visited)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        documentGeneration += 1
        dialogs.beginDocument()
        isPDF = localPDF != nil || pendingPDFTitle != nil
        pdfTitle = pendingPDFTitle
        inputGuard.beginDocument()
        committedRequest = lastRequest
        committedURL = webView.url
        url = displayedDocumentURL
        committedUserAgent = webView.customUserAgent
        invalidateFindResult()
        updateSnapshot()
    }

    private var displayedDocumentURL: URL? {
        (webView.backForwardList.currentItem?.url ?? committedURL)
            .flatMap { $0.absoluteString == "about:blank" ? nil : $0 }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { navigationFailed(navigation, error: error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) { navigationFailed(navigation, error: error) }

    private func navigationFailed(_ navigation: WKNavigation?, error: Error) {
        if let navigation, let activeNavigation, navigation !== activeNavigation { return }
        let error = error as NSError
        if let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL,
           let requestedURL = lastRequest?.url, failedURL != requestedURL { return }
        restoreDisplayedIdentity()
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) else { return }
        updateSnapshot()
        url = lastRequest?.url ?? url
        failure = error.domain == NSURLErrorDomain && (-1206 ... -1200).contains(error.code)
            ? "安全な接続を確認できませんでした。証明書の検証は省略しません。"
            : "ページを読み込めませんでした。接続とURLを確認してください。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dialogs.cancel()
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
