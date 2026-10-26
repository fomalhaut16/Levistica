#if LEVISTICA_MEASUREMENT
import SwiftUI

@MainActor
struct MeasurementViewportStatus: View {
    let page: PageRuntime?
    private struct DocumentKey: Hashable {
        let runtime: ObjectIdentifier?
        let revision: Int
        let loading: Bool
    }
    private struct Request: Equatable {
        let id = UUID()
        let document: DocumentKey
    }
    @State private var request: Request?
    @State private var report = "viewport:not-requested"
    @State private var summary = "viewport:not-requested"

    static let enabled = ProcessInfo.processInfo.environment["LEVISTICA_VIEWPORT_PROBE"] == "1"

    private var document: DocumentKey {
        DocumentKey(runtime: page.map(ObjectIdentifier.init), revision: page?.documentRevision ?? 0,
                    loading: page?.isLoading ?? false)
    }
    private var displayReport: String { page?.isLoading == true ? "viewport:loading" : report }
    private var displaySummary: String { page?.isLoading == true ? "viewport:loading" : summary }

    var body: some View {
        VStack(spacing: 4) {
            Button("表示領域を取得") {
                report = "viewport:requested"
                summary = report
                request = Request(document: document)
            }
                .accessibilityIdentifier("captureMeasurementViewportButton")
                .disabled(page == nil || page?.isLoading == true
                          || report == "viewport:requested" || report == "viewport:pending"
                          || MeasurementViewport.pageID(for: page?.webView.url) == nil)
            Text(displaySummary)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(2)
                .accessibilityIdentifier("measurementViewportReport")
                .accessibilityLabel("表示領域の診断結果")
                .accessibilityValue(displayReport)
        }
        .padding(6)
        .onChange(of: document) {
            request = nil
            report = "viewport:not-requested"
            summary = report
        }
        .task(id: request) {
            guard let request, request.document == document, let page else { return }
            report = "viewport:pending"
            summary = report
            do {
                let snapshot = try await MeasurementViewport.capture(page)
                guard Task.isCancelled == false, request.document == document else { return }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                report = String(decoding: try encoder.encode(snapshot), as: UTF8.self)
                summary = String(format: "%.1f × %.1f · %.2fx", snapshot.cssWidth,
                                 snapshot.cssHeight, snapshot.devicePixelRatio)
            } catch {
                guard Task.isCancelled == false else { return }
                report = "viewport:unavailable"
                summary = report
            }
        }
    }
}
#endif
