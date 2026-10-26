#if DEBUG
import Testing
import WebKit
@testable import Levistica

extension WebKitIntegrationTests {
@MainActor
struct MeasurementViewportTests {
    @Test func onlyFixedPublicDocumentsAndLoopbackFixturesAreEligible() {
        for text in ["https://arxiv.org/pdf/1706.03762v7", "http://127.0.0.1:12345/one",
                     "https://discord.com/login",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ",
                     "https://www.youtube.com/watch?hl=en&v=aqz-KE-bpKQ"] {
            #expect(MeasurementViewport.pageID(for: URL(string: text)) != nil)
        }
        for text in ["https://x.com/i/flow/login", "https://x.com/home", "https://discord.com/channels/@me", "file:///private/synthetic.pdf",
                     "https://x.com/i/flow/login?token=synthetic", "https://discord.com/login#synthetic",
                     "https://user:pass@discord.com/login", "http://discord.com/login",
                     "http://127.0.0.1/one", "http://user:pass@127.0.0.1:12345/one",
                     "http://127.0.0.1:12345/one?token=synthetic", "https://arxiv.org/pdf/other",
                     "https://www.youtube.com/watch?v=other",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ&v=other",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ&list=synthetic",
                     "https://www.youtube.com/watch?v=aqz-KE-bpKQ#synthetic"] {
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
        #expect(snapshot.documentTimeOrigin == nil)
        #expect(snapshot.documentElapsedMilliseconds == nil)
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

    @Test func fixedVideoSnapshotIncludesIntrinsicSizeAndPlaybackState() throws {
        let text = """
        {"width":779,"height":683,"dpr":2,"visualScale":1,"visible":true,"ready":"complete",
         "media":{"width":1280,"height":720,"duration":634.601,"currentTime":30,
                  "paused":false,"muted":true,"readyState":4,"playbackRate":1,"volume":0.1}}
        """
        let bounds = CGRect(x: 0, y: 0, width: 779, height: 683)
        let snapshot = try MeasurementViewport.decode(text, pageID: "public-video", bounds: bounds, zoom: 1)
        #expect(snapshot.media?.height == 720)
        #expect(snapshot.media?.playbackRate == 1)
        #expect(snapshot.media?.volume == 0.1)
        #expect(snapshot.media?.muted == true)
        #expect(snapshot.media?.paused == false)
        #expect(throws: MeasurementViewport.Failure.invalidMetrics) {
            try MeasurementViewport.decode(text, pageID: "public-html", bounds: bounds, zoom: 1)
        }
    }

    @Test func simulatedPublicLoginGeometryNeverIncludesFormContents() async throws {
        let address = "https://discord.com/login"
        let page = PageRuntime(dataStore: .nonPersistent())
        defer { page.stop() }
        page.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let url = try #require(URL(string: address))
        page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
        <title>Synthetic login fixture</title>
        <input type="email" value="synthetic-private-account">
        <input type="password" value="synthetic-private-password">
        <p>synthetic-private-content</p>
        """)
        let deadline = ContinuousClock.now + .seconds(10)
        while page.webView.title != "Synthetic login fixture" || page.webView.isLoading,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(page.webView.title == "Synthetic login fixture" && !page.webView.isLoading)
        let snapshot = try await MeasurementViewport.capture(page)
        #expect(snapshot.pageID == MeasurementViewport.pageID(for: url))
        #expect(snapshot.cssWidth == 640)
        #expect(snapshot.media == nil)
        let data = try JSONEncoder().encode(snapshot)
        let encoded = String(decoding: data, as: UTF8.self)
        #expect(!encoded.contains("synthetic-private"))
        #expect(!encoded.contains("Synthetic login"))
        #expect(!encoded.contains(url.host!))
        let flags = MeasurementViewport.ineligibleDocumentFlags(page)
        #expect(!flags.contains("synthetic-private"))
        #expect(!flags.contains(url.host!))
        let values = try #require(JSONSerialization.jsonObject(with: Data(flags.utf8)) as? [String: Bool])
        #expect(values["pageURLMatchesViewURL"] == true)
        #expect(values["chatHost"] == (url.host == "discord.com"))
    }

    @Test(arguments: [-0.1, 1.1])
    func outOfRangeVolumeIsRejected(_ volume: Double) {
        let payload = """
        {"width":779,"height":683,"dpr":2,"visualScale":1,"visible":true,"ready":"complete",
         "media":{"width":1280,"height":720,"duration":634.601,"currentTime":30,
                  "paused":false,"muted":false,"readyState":4,"volume":\(volume)}}
        """
        #expect(throws: MeasurementViewport.Failure.invalidMedia) {
            try MeasurementViewport.decode(payload, pageID: "public-video",
                bounds: CGRect(x: 0, y: 0, width: 779, height: 683), zoom: 1)
        }
    }

    @Test(arguments: ["\"height\":0", "\"duration\":0", "\"currentTime\":-1", "\"currentTime\":900", "\"playbackRate\":0", "\"playbackRate\":-1"])
    func invalidMediaMetricsAreNotAccepted(_ replacement: String) {
        let valid = """
        {"width":779,"height":683,"dpr":2,"visualScale":1,"visible":true,"ready":"complete",
         "media":{"width":1280,"height":720,"duration":634.601,"currentTime":30,
                  "paused":false,"muted":true,"readyState":4,"playbackRate":1}}
        """
        let key = String(replacement.prefix(through: replacement.firstIndex(of: ":")!))
        let original = key == "\"height\":" ? "\"height\":720" :
            (key == "\"duration\":" ? "\"duration\":634.601" :
                (key == "\"playbackRate\":" ? "\"playbackRate\":1" : "\"currentTime\":30"))
        #expect(throws: MeasurementViewport.Failure.invalidMedia) {
            try MeasurementViewport.decode(valid.replacingOccurrences(of: original, with: replacement),
                pageID: "public-video", bounds: CGRect(x: 0, y: 0, width: 779, height: 683), zoom: 1)
        }
    }

    @Test func videoWithoutLoadedMediaIsNotReady() {
        let text = """
        {"width":779,"height":683,"dpr":2,"visualScale":1,"visible":true,"ready":"complete"}
        """
        #expect(throws: MeasurementViewport.Failure.mediaUnavailable) {
            try MeasurementViewport.decode(text, pageID: "public-video",
                bounds: CGRect(x: 0, y: 0, width: 779, height: 683), zoom: 1)
        }
    }

    @Test(arguments: ["\"timeOrigin\":0", "\"timeOrigin\":-1", "\"timeOrigin\":true", "\"elapsed\":-1"])
    func invalidDocumentTimingIsNotAccepted(_ metadata: String) {
        let text = """
        {"width":640,"height":480,"dpr":2,"visualScale":1,"visible":true,"ready":"complete",\(metadata)}
        """
        #expect(throws: (any Error).self) {
            try MeasurementViewport.decode(text, pageID: "public-html",
                bounds: CGRect(x: 0, y: 0, width: 640, height: 480), zoom: 1)
        }
    }

    @Test func pagePayloadCannotSupplyNativeIdentity() throws {
        let payload = """
        {"width":640,"height":480,"dpr":2,"visualScale":1,"visible":true,"ready":"complete",
         "documentIdentity":{"instance":"00000000-0000-0000-0000-000000000000","revision":999}}
        """
        let bounds = CGRect(x: 0, y: 0, width: 640, height: 480)
        #expect(try MeasurementViewport.decode(payload, pageID: "public-html", bounds: bounds, zoom: 1).documentIdentity == nil)
        let native = MeasurementViewport.DocumentIdentity(instance: UUID(), revision: 2)
        #expect(try MeasurementViewport.decode(payload, pageID: "public-html", bounds: bounds, zoom: 1,
                                             documentIdentity: native).documentIdentity == native)
    }

    @Test func publicHeadingAndNavigationTimingExposeNoPageText() async throws {
        let page = PageRuntime(dataStore: .nonPersistent())
        defer { page.stop() }
        page.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let url = try #require(URL(string: "https://www.w3.org/TR/2024/REC-WCAG22-20241212/"))
        func load(_ title: String, in page: PageRuntime) async throws {
            page.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: """
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'">
            <title>\(title)</title><h1>Web Content Accessibility Guidelines (WCAG) 2.2</h1>
            <input value="synthetic-private-heading-fixture">
            """)
            let deadline = ContinuousClock.now + .seconds(10)
            while page.webView.title != title || page.webView.isLoading, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(page.webView.title == title && page.webView.isLoading == false)
        }
        try await load("Heading fixture one", in: page)
        let first = try await MeasurementViewport.capture(page)
        let origin = try #require(first.documentTimeOrigin)
        #expect(origin > 0)
        #expect(first.documentHeadingMatches == true)
        let again = try await MeasurementViewport.capture(page)
        #expect(try #require(again.documentTimeOrigin) > 0)
        #expect(try #require(again.documentIdentity) == #require(first.documentIdentity))
        #expect(try #require(again.documentElapsedMilliseconds) >= #require(first.documentElapsedMilliseconds))
        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        #expect(encoded.contains("synthetic-private") == false)
        #expect(encoded.contains("Web Content Accessibility") == false)
        #expect(encoded.contains("Heading fixture") == false)
        try await load("Heading fixture two", in: page)
        let replaced = try await MeasurementViewport.capture(page)
        #expect(try #require(replaced.documentTimeOrigin) > 0)
        #expect(try #require(replaced.documentIdentity) != #require(first.documentIdentity))
        #expect(replaced.documentIdentity?.instance == first.documentIdentity?.instance)
        let recreated = PageRuntime(dataStore: .nonPersistent())
        defer { recreated.stop() }
        recreated.webView.frame = page.webView.frame
        try await load("Heading fixture recreated", in: recreated)
        let recreatedSnapshot = try await MeasurementViewport.capture(recreated)
        #expect(try #require(recreatedSnapshot.documentIdentity).instance != #require(first.documentIdentity).instance)
    }
}
}
#endif
