import Testing
import WebKit
@testable import Levistica

// WebKit suites share a process and its services. Serialize the suites
// together, including async suspension points; unrelated pure tests stay parallel.
@Suite(.serialized)
struct WebKitIntegrationTests {}

extension WebKitIntegrationTests {
@MainActor
struct PageInputGuardTests {
    private func httpFixtureURL(environmentKey: String = "LEVISTICA_FIXTURE_URL", path: String) throws -> URL {
        let raw = try #require(ProcessInfo.processInfo.environment[environmentKey], "Run script/test.sh for loopback fixtures.")
        let base = try #require(URL(string: raw))
        try #require(base.scheme == "http" && base.host == "127.0.0.1" && base.port != nil
                     && base.user == nil && base.password == nil && base.query == nil && base.fragment == nil
                     && (base.path.isEmpty || base.path == "/"))
        return base.appendingPathComponent(path)
    }

    @Test(arguments: ["download", "redirect-download"])
    func actualHTTPDownloadPreservesTheDisplayedDocumentAndIdentity(path: String) async throws {
        let destination = try httpFixtureURL(path: path)
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.onDownload = nil; runtime.stop() }
        let pageURL = try #require(URL(string: "https://www.google.com/"))
        runtime.webView.loadSimulatedRequest(URLRequest(url: pageURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>HTTP download fixture</title>")
        let pageDeadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "HTTP download fixture", ContinuousClock.now < pageDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "HTTP download fixture")
        let originalAgent = runtime.webView.customUserAgent ?? ""
        var receivedDownload = false
        var agentAtDownload: String?
        var locationAtDownload: URL?
        runtime.onDownload = { [weak runtime] download in
            agentAtDownload = runtime?.webView.customUserAgent ?? ""
            locationAtDownload = runtime?.url
            receivedDownload = true
            download.cancel { _ in }
        }
        runtime.load(destination)
        let downloadDeadline = ContinuousClock.now + .seconds(15)
        while !receivedDownload, ContinuousClock.now < downloadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(receivedDownload)
        #expect(runtime.webView.title == "HTTP download fixture")
        #expect(runtime.url == pageURL)
        #expect(locationAtDownload == pageURL)
        #expect(runtime.canRetry)
        #expect(runtime.failure == nil)
        #expect(agentAtDownload == originalAgent)
    }

    @Test func actualRedirectRecordsAndReloadsTheFinalDocument() async throws {
        let start = try httpFixtureURL(path: "redirect-two")
        let final = try httpFixtureURL(path: "two")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.onVisit = nil; runtime.stop() }
        var visits: [URL] = []
        runtime.onVisit = { url, _, _ in visits.append(url) }
        runtime.load(start)
        let deadline = ContinuousClock.now + .seconds(10)
        while visits.isEmpty || runtime.webView.title != "Fixture two" || runtime.webView.isLoading,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(visits == [final])
        #expect(runtime.webView.title == "Fixture two")
        #expect(runtime.url == final)
        #expect(runtime.canRetry)
        runtime.reload()
        let reloadDeadline = ContinuousClock.now + .seconds(10)
        while visits.count < 2 || runtime.webView.title != "Fixture two" || runtime.webView.isLoading,
              ContinuousClock.now < reloadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(visits == [final, final])
        #expect(runtime.url == final)
    }

    @Test func actualRedirectFailureKeepsTheDocumentAndFinalRetryDestination() async throws {
        let page = try httpFixtureURL(path: "one")
        let start = try httpFixtureURL(path: "redirect-failure")
        let final = try httpFixtureURL(environmentKey: "LEVISTICA_FAILURE_FIXTURE_URL", path: "failure")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        runtime.load(page)
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Fixture one", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Fixture one")
        runtime.load(start)
        let failureDeadline = ContinuousClock.now + .seconds(15)
        while runtime.failure == nil, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.failure != nil)
        #expect(runtime.webView.title == "Fixture one")
        #expect(runtime.url == final)
        #expect(runtime.canRetry)
    }

    @Test(arguments: [303, 307])
    func actualPOSTRedirectDoesNotReplayTheSubmission(status: Int) async throws {
        let start = try httpFixtureURL(path: "redirect-\(status)")
        let final = try httpFixtureURL(path: status == 303 ? "two" : "redirect-post-target")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        var request = URLRequest(url: start)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic=1".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        runtime.load(request)
        let title = status == 303 ? "Fixture two" : "Redirect POST fixture"
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != title || runtime.webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == title)
        #expect(runtime.url == final)
        #expect(runtime.canRetry == (status == 303))
        let revision = runtime.documentRevision
        runtime.reload()
        if status == 303 {
            let reloadDeadline = ContinuousClock.now + .seconds(10)
            while runtime.documentRevision == revision || runtime.webView.isLoading, ContinuousClock.now < reloadDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(runtime.documentRevision > revision)
            #expect(runtime.failure == nil)
        } else {
            #expect(runtime.failure != nil)
            runtime.retry()
            #expect(runtime.documentRevision == revision)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: httpFixtureURL(path: "redirect-post-count"))
        let counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(counts["post\(status)"] == 1)
    }

    @Test func actualConnectionFailureKeepsTheDocumentAndRetryDestination() async throws {
        let page = try httpFixtureURL(path: "one")
        let failure = try httpFixtureURL(environmentKey: "LEVISTICA_FAILURE_FIXTURE_URL", path: "failure")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        runtime.load(page)
        let pageDeadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Fixture one", ContinuousClock.now < pageDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Fixture one")
        runtime.load(failure)
        let failureDeadline = ContinuousClock.now + .seconds(15)
        while runtime.failure == nil, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.failure != nil)
        #expect(runtime.webView.title == "Fixture one")
        #expect(runtime.url == failure)
        #expect(runtime.canRetry)
    }

    @Test(arguments: [false, true])
    func stoppingPreservesIdentityCapturedAtCommit(googleIdentity: Bool) async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        let initialURL = try #require(URL(string: googleIdentity ? "https://example.org/" : "https://www.google.com/"))
        let finalURL = try #require(URL(string: googleIdentity ? "https://www.google.com/" : "https://example.org/"))
        runtime.webView.loadSimulatedRequest(URLRequest(url: initialURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Commit identity fixture</title>")
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Commit identity fixture", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Commit identity fixture")
        // Model the delegate's final-response selection and commit separately.
        // loadSimulatedRequest itself does not reproduce a network redirect.
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: finalURL)
        runtime.webView(runtime.webView, didCommit: nil)
        let selectedAgent = runtime.webView.customUserAgent ?? ""
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: initialURL)
        runtime.stop()
        #expect((runtime.webView.customUserAgent ?? "") == selectedAgent)
    }

    @Test(arguments: ["https://www.google.com/", "https://example.org/"], ["stop", "failure", "cancel"])
    func interruptedNavigationKeepsTheDisplayedDocumentIdentity(address: String, interruption: String) async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        let pageURL = try #require(URL(string: address))
        runtime.webView.loadSimulatedRequest(URLRequest(url: pageURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Interruption fixture</title>")
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Interruption fixture", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Interruption fixture")
        func documentAgent() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                runtime.webView.evaluateJavaScript("navigator.userAgent") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
        }
        let originalAgent = try await documentAgent()
        // Model the accepted provisional destination before a new document commits.
        // Its identity differs from the still-displayed, fully loaded fixture.
        let pendingURL = try #require(URL(string: address.contains("google") ? "https://example.org/" : "https://www.google.com/"))
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: pendingURL)
        if interruption == "stop" {
            runtime.stop()
        } else {
            runtime.webView(runtime.webView, didFailProvisionalNavigation: nil,
                            withError: URLError(interruption == "cancel" ? .cancelled : .cannotConnectToHost))
        }
        #expect(runtime.webView.title == "Interruption fixture")
        #expect(try await documentAgent() == originalAgent)
        if interruption == "failure" { #expect(runtime.failure != nil) }
    }

    @Test func simulatedMainNavigationsResetGoogleIdentityWithoutNetworkAccess() async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        for (index, address) in ["https://www.google.com/", "https://example.org/", "https://www.google.co.jp/",
                                 "https://accounts.google.com/"].enumerated() {
            let destination = try #require(URL(string: address))
            let title = "Identity fixture \(index)"
            runtime.webView.loadSimulatedRequest(URLRequest(url: destination), responseHTML:
                "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>\(title)</title></head><body>Fixture</body></html>")
            let deadline = ContinuousClock.now + .seconds(10)
            while (runtime.webView.isLoading || runtime.webView.title != title), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.webView.title == title)
            #expect(runtime.webView.url == destination)
            if let expected = NavigationPolicy.userAgent(for: destination) {
                #expect(runtime.webView.customUserAgent == expected)
            } else {
                // WebKit normalizes a cleared custom agent to an empty string.
                #expect(runtime.webView.customUserAgent?.isEmpty ?? true)
            }
            let agent: String = try await withCheckedThrowingContinuation { continuation in
                runtime.webView.evaluateJavaScript("navigator.userAgent") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
            if let expected = NavigationPolicy.userAgent(for: destination) {
                #expect(agent == expected)
            } else {
                #expect(agent.contains("Levistica") == false)
            }
        }
    }

    @Test func inheritedConfigurationPreservesScriptsWithoutSharingInputObservers() {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let marker = "globalThis.levisticaSyntheticMarker = true;"
        configuration.userContentController.addUserScript(WKUserScript(source: marker, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true))
        let parent = PageRuntime(configuration: configuration)
        let child = PageRuntime(configuration: parent.webView.configuration, permitsInitialBlankPage: true)
        let parentController = parent.webView.configuration.userContentController
        let childController = child.webView.configuration.userContentController
        #expect(parent.inputGuard !== child.inputGuard)
        #expect(parentController !== childController)
        #expect(child.webView.configuration.websiteDataStore === store)
        #expect(childController.userScripts.contains { $0.source == marker })
        #expect(childController.userScripts.count == parentController.userScripts.count)
    }

    @Test func inputObserverDoesNotRetainItsWebView() {
        weak var view: WKWebView?
        weak var observer: PageInputGuard?
        autoreleasepool {
            let runtime = PageRuntime(dataStore: .nonPersistent())
            view = runtime.webView
            observer = runtime.inputGuard
        }
        #expect(view == nil)
        #expect(observer == nil)
    }

    @Test func endingTheRuntimeReleasesItsInputController() async throws {
        weak var controller: WKUserContentController?
        autoreleasepool {
            let runtime = PageRuntime(dataStore: .nonPersistent())
            controller = runtime.webView.configuration.userContentController
            #expect(controller != nil)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while controller != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller == nil)
    }
}
}
