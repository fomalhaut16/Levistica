import Testing
import WebKit
@testable import Levistica

@MainActor
struct PageInputGuardTests {
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
}
