#if DEBUG || LEVISTICA_MEASUREMENT
import Foundation
import WebKit

@MainActor
enum MeasurementViewport {
    enum Failure: Error, Equatable { case ineligibleDocument, notReady, unavailable, invalidMetrics, documentChanged }

    struct Snapshot: Codable, Equatable, Sendable {
        let schema: Int
        let pageID: String
        let cssWidth: Double
        let cssHeight: Double
        let devicePixelRatio: Double
        let visualScale: Double
        let nativeWidth: Double
        let nativeHeight: Double
        let pageZoom: Double
        let documentVisible: Bool
        let capturedAtEpochSeconds: Double
    }

    private struct Payload: Decodable {
        let width: Double
        let height: Double
        let dpr: Double
        let visualScale: Double
        let visible: Bool
        let ready: String
    }

    static func pageID(for url: URL?) -> String? {
        guard let url else { return nil }
        let fixed = [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en": "public-video",
            "https://www.w3.org/TR/2024/REC-WCAG22-20241212/": "public-html",
            "https://arxiv.org/pdf/1706.03762v7": "public-pdf"
        ]
        if let id = fixed[url.absoluteString] { return id }
        if url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
           (1...65535).contains(port), url.user == nil, url.password == nil,
           url.query == nil, url.fragment == nil, ["/one", "/two"].contains(url.path) {
            return "loopback-fixture"
        }
        #if DEBUG
        if url.absoluteString == "https://example.invalid/viewport-fixture" { return "generated-document" }
        #endif
        return nil
    }

    static func decode(_ encoded: String, pageID: String, bounds: CGRect, zoom: Double) throws -> Snapshot {
        guard let data = encoded.data(using: .utf8), let value = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.invalidMetrics
        }
        let numbers = [value.width, value.height, value.dpr, value.visualScale,
                       Double(bounds.width), Double(bounds.height), zoom]
        guard numbers.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidMetrics }
        guard value.ready == "complete" else { throw Failure.notReady }
        return Snapshot(schema: 1, pageID: pageID, cssWidth: value.width, cssHeight: value.height,
                        devicePixelRatio: value.dpr, visualScale: value.visualScale,
                        nativeWidth: bounds.width, nativeHeight: bounds.height, pageZoom: zoom,
                        documentVisible: value.visible, capturedAtEpochSeconds: Date().timeIntervalSince1970)
    }

    static func capture(_ page: PageRuntime) async throws -> Snapshot {
        let view = page.webView
        guard let id = pageID(for: view.url), page.localPDF == nil else { throw Failure.ineligibleDocument }
        guard page.failure == nil, view.isLoading == false else { throw Failure.notReady }
        let url = view.url, revision = page.documentRevision, bounds = view.bounds, zoom = view.pageZoom
        // A fixed read in the isolated client world; no page-to-native message handler or content values.
        let script = """
        JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
          visualScale:visualViewport ? visualViewport.scale : 1,
          visible:document.visibilityState === 'visible',ready:document.readyState})
        """
        let encoded: String = try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                guard case .success(let value) = result, let encoded = value as? String else {
                    continuation.resume(throwing: Failure.unavailable)
                    return
                }
                continuation.resume(returning: encoded)
            }
        }
        guard view.url == url, page.documentRevision == revision, view.isLoading == false,
              view.bounds == bounds, view.pageZoom == zoom else { throw Failure.documentChanged }
        try Task.checkCancellation()
        return try decode(encoded, pageID: id, bounds: bounds, zoom: zoom)
    }
}
#endif
