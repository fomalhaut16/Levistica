#if DEBUG
import Testing
import WebKit
@testable import Levistica

extension WebKitIntegrationTests {
@MainActor
struct MeasurementViewportTests {
    @Test func onlyFixedPublicDocumentsAndLoopbackFixturesAreEligible() {
        for text in ["https://arxiv.org/pdf/1706.03762v7", "http://127.0.0.1:12345/one",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en"] {
            #expect(MeasurementViewport.pageID(for: URL(string: text)) != nil)
        }
        for text in ["https://x.com/i/flow/login", "file:///private/synthetic.pdf",
                     "http://127.0.0.1/one", "http://user:pass@127.0.0.1:12345/one",
                     "http://127.0.0.1:12345/one?token=synthetic", "https://arxiv.org/pdf/other"] {
            #expect(MeasurementViewport.pageID(for: URL(string: text)) == nil)
        }
    }

    @Test(arguments: ["0", "-1", "1e309", "null", "true"])
    func invalidWidthNeverBecomesZeroOrAValidSnapshot(_ width: String) {
        let text = """
        {"width":\(width),"height":480,"dpr":2,"visualScale":1,"visible":true,"ready":"complete"}
        """
        #expect(throws: (any Error).self) {
            try MeasurementViewport.decode(text, pageID: "generated-document",
                                           bounds: CGRect(x: 0, y: 0, width: 640, height: 480), zoom: 1)
        }
    }

    @Test func hiddenDocumentIsExplicitAndDoesNotImplyVisibleReadiness() throws {
        let text = """
        {"width":640,"height":480,"dpr":2,"visualScale":1,"visible":false,"ready":"complete"}
        """
        let snapshot = try MeasurementViewport.decode(text, pageID: "generated-document",
            bounds: CGRect(x: 0, y: 0, width: 640, height: 480), zoom: 1)
        #expect(snapshot.documentVisible == false)
        #expect(snapshot.cssWidth == 640)
        #expect(throws: MeasurementViewport.Failure.invalidMetrics) {
            try MeasurementViewport.decode(text, pageID: "generated-document", bounds: .zero, zoom: 1)
        }
        #expect(throws: MeasurementViewport.Failure.notReady) {
            try MeasurementViewport.decode(text.replacingOccurrences(of: "complete", with: "loading"),
                pageID: "generated-document", bounds: CGRect(x: 0, y: 0, width: 640, height: 480), zoom: 1)
        }
    }

    @Test func realWebKitGeometryUsesTheIsolatedWorldAndExcludesContent() async throws {
        let page = PageRuntime(dataStore: .nonPersistent())
        defer { page.stop() }
        page.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let url = try #require(URL(string: "https://example.invalid/viewport-fixture"))
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'">
        <title>Viewport fixture</title><input value="synthetic-private-value">
        <script>Object.defineProperty(window,'innerWidth',{get:()=>99999});</script>
        """)
        let deadline = ContinuousClock.now + .seconds(10)
        while page.webView.title != "Viewport fixture" || page.webView.isLoading,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(page.webView.title == "Viewport fixture" && page.webView.isLoading == false)
        let overridden: Double = try await withCheckedThrowingContinuation { continuation in
            page.webView.evaluateJavaScript("innerWidth") { value, error in
                if let number = value as? NSNumber, error == nil {
                    continuation.resume(returning: number.doubleValue)
                } else { continuation.resume(throwing: MeasurementViewport.Failure.unavailable) }
            }
        }
        try #require(overridden == 99999)
        let snapshot = try await MeasurementViewport.capture(page)
        #expect(snapshot.cssWidth == 640)
        #expect(snapshot.cssHeight == 480)
        #expect(snapshot.devicePixelRatio > 0)
        #expect(snapshot.nativeWidth == 640)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(encoded.contains("synthetic-private-value") == false)
        #expect(encoded.contains("example.invalid") == false)
        #expect(encoded.contains("Viewport fixture") == false)
    }
}
}
#endif
