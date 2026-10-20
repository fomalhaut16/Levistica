import Foundation
import Testing
@testable import Levistica

struct NavigationPolicyTests {
    @Test(arguments: ["https://example.com", "http://127.0.0.1:8080/"])
    func acceptsWebPages(input: String) {
        #expect(NavigationPolicy.allows(URL(string: input), isMainFrame: true))
    }

    @Test(arguments: ["file:///etc/passwd", "javascript:alert(1)", "mailto:a@example.com", "x-apple.systempreferences:privacy", "data:text/html,hello", "https://user:password@example.com"])
    func refusesUnsafeTopLevelNavigation(input: String) {
        #expect(NavigationPolicy.allows(URL(string: input), isMainFrame: true) == false)
    }

    @Test func embeddedDocumentDoesNotGrantNativeAccess() {
        #expect(NavigationPolicy.allows(URL(string: "about:blank"), isMainFrame: false))
        #expect(NavigationPolicy.allows(URL(string: "file:///etc/passwd"), isMainFrame: false) == false)
        #expect(NavigationPolicy.allows(nil, isMainFrame: false) == false)
    }
}
