import Foundation
import Testing
import WebKit
@testable import Levistica

struct NavigationPolicyTests {
    @Test(arguments: ["https://google.com/", "https://www.google.com/search?q=test",
                      "https://www.google.co.jp/", "https://google.co.jp:443/", "https://WWW.GOOGLE.COM/"])
    func googleDesktopIdentityUsesOnlyCompatibilityTokens(input: String) throws {
        let agent = try #require(NavigationPolicy.userAgent(for: URL(string: input)))
        #expect(agent.contains("Safari/605.1.15"))
        #expect(agent.contains("Levistica"))
        #expect(agent.contains("Chrome/") == false)
        #expect(agent.contains("Version/") == false)
    }

    @Test(arguments: ["http://www.google.com/", "https://www.google.com:8443/", "https://accounts.google.com/",
                      "https://docs.google.com/", "https://www.google.com.example.org/", "https://notgoogle.com/",
                      "https://example.org/?next=https://www.google.com/", "https://www.google.com@example.org/",
                      "https://user@www.google.com/", "file:///www.google.com", "about:blank"])
    func unrelatedOrAmbiguousDestinationsKeepWebKitIdentity(input: String) {
        #expect(NavigationPolicy.userAgent(for: URL(string: input)) == nil)
    }

    @Test func missingDestinationKeepsDefaultIdentity() {
        #expect(NavigationPolicy.userAgent(for: nil) == nil)
    }

    @Test(arguments: ["about:blank", "https://example.com/login", "http://127.0.0.1:8080/callback"])
    func acceptsRelatedWebContexts(input: String) {
        #expect(NavigationPolicy.allowsNewContext(URL(string: input)))
    }

    @Test func anEmptyRelatedContextDoesNotEnableEmptyOrdinaryNavigation() {
        #expect(NavigationPolicy.allowsNewContext(nil))
        #expect(NavigationPolicy.allowsNewContext(URL(string: "")))
        #expect(NavigationPolicy.allows(nil, isMainFrame: true) == false)
        #expect(NavigationPolicy.allows(URL(string: "about:blank"), isMainFrame: true) == false)
    }

    @Test(arguments: ["about:config", "data:text/html,hello", "javascript:alert(1)", "file:///etc/passwd", "https://u:p@example.com", "http://127.0.0.1:1"])
    func relatedContextDoesNotGrantExtraSchemeAccess(input: String) {
        #expect(NavigationPolicy.allowsNewContext(URL(string: input)) == false)
    }
    @Test(arguments: ["https://example.com", "http://127.0.0.1:8080/"])
    func acceptsWebPages(input: String) {
        #expect(NavigationPolicy.allows(URL(string: input), isMainFrame: true))
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "mailto:a@example.com", "x-apple.systempreferences:privacy", "data:text/html,hello", "https://user:password@example.com", "http://127.0.0.1:1/"])
    func refusesUnsafeTopLevelNavigation(input: String) {
        #expect(NavigationPolicy.allows(URL(string: input), isMainFrame: true) == false)
    }

    @Test func embeddedDocumentDoesNotGrantNativeAccess() {
        #expect(NavigationPolicy.allows(URL(string: "about:blank"), isMainFrame: false))
        #expect(NavigationPolicy.allows(URL(string: "file:///etc/passwd"), isMainFrame: false) == false)
        #expect(NavigationPolicy.allows(nil, isMainFrame: false) == false)
    }
}

struct WebKitBrowserIdentityTests {
    @Test(arguments: ["26.6", "27.0", "18.6.1"])
    func compatibilityVersionComesFromValidatedMetadata(version: String) {
        let name = WebKitBrowserIdentity.applicationName(safariVersion: version, appVersion: "0.1.0")
        #expect(name == "Version/\(version) Safari/605.1.15 Levistica/0.1.0")
        #expect(name.contains("Chrome") == false)
    }

    @Test(arguments: [nil, "", "26.6\n", "26.6\r\nInjected: value", "２６.６", "26..6", "26.6 beta", "1.2.3.4.5",
                      String(repeating: "1", count: 33)] as [String?])
    func missingOrMalformedMetadataDoesNotInventCompatibility(version: String?) {
        #expect(WebKitBrowserIdentity.applicationName(safariVersion: version, appVersion: "0.1.0") == "Levistica/0.1.0")
    }

    @Test func invalidApplicationMetadataCannotAddHeaderTokens() {
        #expect(WebKitBrowserIdentity.applicationName(safariVersion: nil, appVersion: nil) == "Levistica")
        #expect(WebKitBrowserIdentity.applicationName(safariVersion: "26.6", appVersion: "1 Fake/99")
                == "Version/26.6 Safari/605.1.15 Levistica")
    }
}

struct PageConnectionInfoTests {
    private func info(_ value: String?, loading: Bool = false, secure: Bool = true,
                      failed: Bool = false, localPDF: Bool = false) -> PageConnectionInfo {
        PageConnectionInfo(documentURL: value.flatMap(URL.init(string:)), isLoading: loading,
                           hasOnlySecureContent: secure, failed: failed, isLocalPDF: localPDF)
    }

    @Test func onlyCommittedHTTPSGetsAnHTTPSLabel() {
        #expect(info(nil).kind == .none)
        #expect(info(nil, loading: true).kind == .loading)
        #expect(info("https://example.org/", loading: true).kind == .loading)
        #expect(info("https://example.org/", failed: true).kind == .unavailable)
        #expect(info("https://example.org/").kind == .https)
        #expect(info("https://example.org/", secure: false).kind == .mixedContent)
        #expect(info("http://example.org/").kind == .http)
    }

    @Test func originOmitsPathsQueriesFragmentsAndDefaultPorts() {
        #expect(info("https://EXAMPLE.org:443/synthetic?private=fixture#fragment").origin == "https://example.org")
        #expect(info("http://example.org:80/path").origin == "http://example.org")
        #expect(info("https://example.org:8443/path").origin == "https://example.org:8443")
        #expect(info("http://[::1]:8080/path").origin == "http://[::1]:8080")
        #expect(info("https://例え.テスト/path").origin == "https://xn--r8jz45g.xn--zckzah")
    }

    @Test(arguments: ["https://synthetic:fixture@example.org/", "about:blank", "data:text/html,fixture", "file:///tmp/synthetic.pdf"])
    func unsupportedOrCredentialBearingURLsDoNotClaimTLS(value: String) {
        #expect(info(value).kind == .none)
        #expect(info(value).origin == nil)
    }

    @Test func localPDFHasNoNetworkOrigin() {
        let result = info("file:///tmp/synthetic.pdf", localPDF: true)
        #expect(result.kind == .localPDF)
        #expect(result.origin == nil)
    }

    @Test @MainActor func uncommittedRequestsAndProcessFailureNeverKeepATLSLabel() {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        #expect(runtime.connectionInfo.kind == .none)
        runtime.load(URLRequest(url: URL(string: "https://example.invalid/synthetic")!))
        #expect(runtime.connectionInfo.kind != .https)
        runtime.webViewWebContentProcessDidTerminate(runtime.webView)
        #expect(runtime.connectionInfo.kind == .unavailable)
        runtime.dismissFailure()
        #expect(runtime.connectionInfo.kind != .https)
        #expect(runtime.connectionDocumentURL == nil)
        runtime.webView.stopLoading()
    }
}
