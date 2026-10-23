import Foundation
import Testing
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
