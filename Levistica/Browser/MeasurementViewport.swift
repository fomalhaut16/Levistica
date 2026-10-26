#if DEBUG || LEVISTICA_MEASUREMENT
import Foundation
import WebKit

@MainActor
enum MeasurementViewport {
    enum Failure: String, Error, Equatable {
        case ineligibleDocument, notReady, unavailable, invalidMetrics, documentChanged, mediaUnavailable, invalidMedia
    }

    struct Media: Codable, Equatable, Sendable {
        let width: Double
        let height: Double
        let duration: Double
        let currentTime: Double
        let paused: Bool
        let muted: Bool
        let readyState: Int
    }

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
        let media: Media?
    }

    private struct Payload: Decodable {
        let width: Double
        let height: Double
        let dpr: Double
        let visualScale: Double
        let visible: Bool
        let ready: String
        let media: Media?
    }

    static func pageID(for url: URL?) -> String? {
        guard let url else { return nil }
        let fixed = [
            "https://www.youtube.com/watch?v=aqz-KE-bpKQ&hl=en": "public-video",
            "https://www.w3.org/TR/2024/REC-WCAG22-20241212/": "public-html",
            "https://arxiv.org/pdf/1706.03762v7": "public-pdf"
        ]
        if let id = fixed[url.absoluteString] { return id }
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.scheme == "https", parts.host == "www.youtube.com", parts.path == "/watch",
           parts.user == nil, parts.password == nil, parts.port == nil,
           parts.fragment == nil || parts.fragment == "" {
            let items = parts.queryItems ?? []
            let videos = items.filter { $0.name == "v" }
            let languages = items.filter { $0.name == "hl" }
            if items.allSatisfy({ ["v", "hl"].contains($0.name) }),
               videos.count == 1, videos[0].value == "aqz-KE-bpKQ",
               languages.count <= 1, languages.allSatisfy({ $0.value == "en" }) {
                return "public-video"
            }
        }
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

    static func ineligibleDocumentFlags(_ page: PageRuntime) -> String {
        let parts = page.webView.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let items = parts?.queryItems ?? []
        let flags = ["videoHost": parts?.host == "www.youtube.com", "videoPath": parts?.path == "/watch",
                     "movieID": items.contains { $0.name == "v" && $0.value == "aqz-KE-bpKQ" },
                     "onlyVideoAndLanguageKeys": items.allSatisfy { ["v", "hl"].contains($0.name) },
                     "englishParameter": items.contains { $0.name == "hl" && $0.value == "en" },
                     "fragmentAbsent": parts?.fragment == nil || parts?.fragment == "",
                     "localPDFAbsent": page.localPDF == nil]
        guard let data = try? JSONSerialization.data(withJSONObject: flags, options: .sortedKeys) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ encoded: String, pageID: String, bounds: CGRect, zoom: Double) throws -> Snapshot {
        guard let data = encoded.data(using: .utf8), let value = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw Failure.invalidMetrics
        }
        let numbers = [value.width, value.height, value.dpr, value.visualScale,
                       Double(bounds.width), Double(bounds.height), zoom]
        guard numbers.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidMetrics }
        guard value.ready == "complete" else { throw Failure.notReady }
        if pageID == "public-video" {
            guard let media = value.media else { throw Failure.mediaUnavailable }
            guard [media.width, media.height, media.duration].allSatisfy({ $0.isFinite && $0 > 0 }),
                  media.currentTime.isFinite, media.currentTime >= 0,
                  media.currentTime <= media.duration else { throw Failure.invalidMedia }
            guard (2...4).contains(media.readyState) else { throw Failure.notReady }
        } else if value.media != nil { throw Failure.invalidMetrics }
        return Snapshot(schema: 1, pageID: pageID, cssWidth: value.width, cssHeight: value.height,
                        devicePixelRatio: value.dpr, visualScale: value.visualScale,
                        nativeWidth: bounds.width, nativeHeight: bounds.height, pageZoom: zoom,
                        documentVisible: value.visible, capturedAtEpochSeconds: Date().timeIntervalSince1970,
                        media: value.media)
    }

    static func capture(_ page: PageRuntime) async throws -> Snapshot {
        let view = page.webView
        guard let id = pageID(for: view.url), page.localPDF == nil else { throw Failure.ineligibleDocument }
        guard page.failure == nil, view.isLoading == false else { throw Failure.notReady }
        let url = view.url, revision = page.documentRevision, bounds = view.bounds, zoom = view.pageZoom
        // A fixed read in the isolated client world; no page-to-native message handler or content values.
        let script = """
        (() => {
        const v = \(id == "public-video" ? "document.querySelector('video.html5-main-video')" : "null");
        const media = v ? {width:v.videoWidth,height:v.videoHeight,duration:v.duration,
          currentTime:v.currentTime,paused:v.paused,muted:v.muted,readyState:v.readyState} : null;
        return JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,
          visualScale:visualViewport ? visualViewport.scale : 1,
          visible:document.visibilityState === 'visible',ready:document.readyState,media});
        })()
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
