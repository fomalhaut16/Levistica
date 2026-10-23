import Testing
import WebKit
@testable import Levistica

@MainActor
struct PageInputGuardTests {
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
