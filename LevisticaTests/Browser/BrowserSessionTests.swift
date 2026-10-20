import Testing
import WebKit
@testable import Levistica

@MainActor
struct BrowserSessionTests {
    @Test func securityDelegatesAreExposedToWebKit() {
        let page = PageRuntime(dataStore: .nonPersistent())
        #expect(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")))
        #expect(page.responds(to: NSSelectorFromString("webView:decidePolicyForNavigationResponse:decisionHandler:")))
        #expect(page.responds(to: NSSelectorFromString("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:")))
    }

    @Test func invalidInputDoesNotAllocateWebView() {
        let session = BrowserSession()
        #expect(session.page == nil)
        #expect(session.navigate("javascript:alert(1)") == false)
        #expect(session.page == nil)
        #expect(session.inputError != nil)
    }

    @Test func runtimeCanBeReleasedWithItsWebView() {
        weak var runtime: PageRuntime?
        weak var view: WKWebView?
        autoreleasepool {
            let page = PageRuntime(dataStore: .nonPersistent())
            runtime = page
            view = page.webView
            #expect(runtime != nil)
        }
        #expect(runtime == nil)
        #expect(view == nil)
    }

    @Test func processTerminationIsReportedWithoutReplacingThePage() {
        let page = PageRuntime(dataStore: .nonPersistent())
        let view = page.webView
        page.webViewWebContentProcessDidTerminate(view)
        #expect(page.failure != nil)
        #expect(page.webView === view)
        #expect(page.isLoading == false)
    }
}
