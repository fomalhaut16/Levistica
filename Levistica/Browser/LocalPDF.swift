import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// Own only the selected file's security scope for this runtime. Never grant its
// containing directory, create bookmarks, or copy the document into the profile.
final class LocalPDF {
    let url: URL
    private let scopedURL: URL
    private let scoped: Bool

    enum Failure: LocalizedError, Equatable {
        case unreadable, invalid, encrypted
        var errorDescription: String? {
            switch self {
            case .unreadable: "PDFを読み取れませんでした。ファイルの所在とアクセス権を確認して選び直してください。"
            case .invalid: "このファイルをPDFとして開けませんでした。元のファイルを確認してください。"
            case .encrypted: "暗号化されたPDFには、まだ対応していません。"
            }
        }
    }

    init(selectedURL: URL) throws {
        guard selectedURL.isFileURL, selectedURL.host == nil || selectedURL.host == "localhost",
              selectedURL.query == nil, selectedURL.fragment == nil else { throw Failure.unreadable }
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        let candidate = selectedURL.standardizedFileURL
        do {
            let values = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: candidate.path) else { throw Failure.unreadable }
            guard let document = CGPDFDocument(candidate as CFURL) else { throw Failure.invalid }
            guard !document.isEncrypted else { throw Failure.encrypted }
            guard document.numberOfPages > 0 else { throw Failure.invalid }
        } catch {
            if scoped { selectedURL.stopAccessingSecurityScopedResource() }
            throw (error as? Failure) ?? Failure.unreadable
        }
        // Initialize ownership only after validation. A fully initialized Swift
        // object also runs deinit if its initializer subsequently throws.
        scopedURL = selectedURL
        self.scoped = scoped
        url = candidate
    }

    deinit { if scoped { scopedURL.stopAccessingSecurityScopedResource() } }

    func allows(_ candidate: URL?) -> Bool {
        guard let candidate, candidate.isFileURL, candidate.query == nil,
              candidate.host == nil || candidate.host == "localhost",
              var parts = URLComponents(url: candidate, resolvingAgainstBaseURL: false) else { return false }
        parts.fragment = nil
        return parts.url?.standardizedFileURL == url
    }

    @MainActor static func panel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "PDFを開く"
        panel.prompt = "開く"
        panel.message = "選択したPDFを新しいタブで開きます。入力・注釈の保存には対応していません。"
        panel.allowedContentTypes = [.pdf]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let directory = FilePanelDefaults.testDirectory { panel.directoryURL = directory }
        return panel
    }
}
