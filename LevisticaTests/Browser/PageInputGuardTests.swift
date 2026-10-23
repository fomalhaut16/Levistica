import Testing
import WebKit
@testable import Levistica

@MainActor
struct PageInputGuardTests {
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
