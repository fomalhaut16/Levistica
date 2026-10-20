import AppKit
import CoreServices
import Observation
import WebKit

enum FilePanelDefaults {
    static var testDirectory: URL? {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["LEVISTICA_EPHEMERAL"] == "1",
           let value = environment["LEVISTICA_FILE_TEST_ID"], let id = UUID(uuidString: value),
           let path = environment["LEVISTICA_FILE_TEST_DIRECTORY"], path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if url.lastPathComponent == "LevisticaFiles-" + id.uuidString { return url }
        }
        #endif
        return nil
    }
}

// The replacement directory is on the destination volume, so promotion is a rename.
final class DownloadDestination {
    let url: URL
    let directory: URL
    let stagingURL: URL
    private let scoped: Bool
    private let existed: Bool
    private let originalFingerprint: Fingerprint?

    private struct Fingerprint: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        existed = FileManager.default.fileExists(atPath: url.path)
        do {
            if existed {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
            }
            originalFingerprint = try (existed ? Fingerprint(url: url) : nil)
            directory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: url, create: true)
            stagingURL = directory.appendingPathComponent("payload.partial")
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func finish() throws {
        let manager = FileManager.default
        let values = try stagingURL.resourceValues(forKeys: [.isRegularFileKey, .quarantinePropertiesKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        var quarantine = values.quarantineProperties ?? [:]
        quarantine[kLSQuarantineAgentNameKey as String] = "Levistica"
        quarantine[kLSQuarantineTypeKey as String] = kLSQuarantineTypeWebDownload
        quarantine[kLSQuarantineTimeStampKey as String] = Date()
        var resources = URLResourceValues()
        resources.quarantineProperties = quarantine
        var stage = stagingURL
        try stage.setResourceValues(resources)
        if existed {
            let target = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard target.isRegularFile == true, target.isSymbolicLink != true else { throw CocoaError(.fileWriteFileExists) }
            guard try Fingerprint(url: url) == originalFingerprint else { throw CocoaError(.fileWriteFileExists) }
            _ = try manager.replaceItemAt(url, withItemAt: stagingURL, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            // moveItem refuses a destination created since the Save dialog.
            try manager.moveItem(at: stagingURL, to: url)
        }
        cleanup()
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

@MainActor @Observable
final class DownloadItem: Identifiable {
    let id = UUID()
    let tabID: UUID
    var filename = "保存先を選択中"
    var status = "保存先を選択中"
    var active = true
    var completed = false
    var choosingDestination = true
    var received: Int64 = 0
    var total: Int64 = -1
    @ObservationIgnored var download: WKDownload?
    @ObservationIgnored var destination: DownloadDestination?
    @ObservationIgnored var observation: NSKeyValueObservation?
    @ObservationIgnored var panel: NSSavePanel?

    init(download: WKDownload, tabID: UUID) { self.download = download; self.tabID = tabID }
}

@MainActor @Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    private(set) var items: [DownloadItem] = []
    var notice: String?
    @ObservationIgnored private var quitAfterCancelling = false

    var hasActive: Bool { items.contains(where: \.active) }
    func hasActive(tabID: UUID) -> Bool { items.contains { $0.tabID == tabID && $0.active } }

    func accept(_ download: WKDownload, tabID: UUID) {
        if items.contains(where: { $0.active && $0.choosingDestination }) {
            notice = "保存先を選択してから、次のダウンロードを始めてください。"
            download.cancel { _ in }
            return
        }
        guard items.filter(\.active).count < 4 else {
            notice = "同時に保存できるのは4件までです。完了してから、もう一度リンクを開いてください。"
            download.cancel { _ in }
            return
        }
        while items.count >= 20, let index = items.lastIndex(where: { !$0.active }) {
            items.remove(at: index)
        }
        let item = DownloadItem(download: download, tabID: tabID)
        items.insert(item, at: 0)
        download.delegate = self
        item.observation = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak item] _, _ in
            self?.scheduleProgress(item)
        }
    }

    nonisolated private func scheduleProgress(_ item: DownloadItem?) {
        Task { @MainActor [weak item] in
            guard let item, item.active, let download = item.download else { return }
            item.received = download.progress.completedUnitCount
            item.total = download.progress.totalUnitCount
        }
    }

    private func item(for download: WKDownload) -> DownloadItem? { items.first { $0.download === download } }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let item = item(for: download), item.active else { completionHandler(nil); return }
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            completionHandler(nil)
            finish(item, status: "サーバーがファイルを返しませんでした。")
            return
        }
        let panel = NSSavePanel()
        panel.title = "ダウンロードの保存先"
        panel.prompt = "保存"
        if let directory = FilePanelDefaults.testDirectory { panel.directoryURL = directory }
        let origin = download.originatingFrame.securityOrigin
        var source = URLComponents()
        source.scheme = origin.protocol
        source.host = origin.host
        if origin.port > 0 { source.port = origin.port }
        panel.message = "要求元: \(source.string ?? "不明な要求元")\n転送が完了してからファイルを保存します。"
        panel.nameFieldStringValue = Self.safeFilename(suggestedFilename)
        panel.canCreateDirectories = true
        item.filename = panel.nameFieldStringValue
        item.panel = panel
        panel.begin { [weak self, weak item] result in
            guard let self, let item else { completionHandler(nil); return }
            item.panel = nil
            item.choosingDestination = false
            guard item.active, result == .OK, let url = panel.url else {
                completionHandler(nil)
                self.finish(item, status: "取り消しました")
                return
            }
            do {
                item.destination = try DownloadDestination(url: url)
                item.filename = url.lastPathComponent
                item.status = "ダウンロード中"
                completionHandler(item.destination?.stagingURL)
            } catch {
                completionHandler(nil)
                self.finish(item, status: "保存先に書き込めませんでした。別の保存先で試してください。")
            }
        }
    }

    static func safeFilename(_ suggestion: String) -> String {
        let name = (suggestion as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "_")
        var bounded = String(name.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        while bounded.utf8.count > 180 { bounded.removeLast() }
        return bounded.isEmpty || bounded == "." || bounded == ".." ? "download" : bounded
    }

    func cancel(_ item: DownloadItem) {
        guard item.active else { return }
        item.status = "取り消し中"
        if let panel = item.panel { panel.cancel(nil); return }
        item.download?.cancel { [weak self, weak item] _ in
            guard let self, let item else { return }
            item.destination?.cleanup()
            item.destination = nil
            self.finish(item, status: "取り消しました")
        }
    }

    func cancelAllAndQuit() {
        quitAfterCancelling = true
        for item in items where item.active { cancel(item) }
        checkQuit()
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), item.active else { return }
        do {
            guard let destination = item.destination else { throw CocoaError(.fileWriteUnknown) }
            try destination.finish()
            item.completed = true
            finish(item, status: "保存しました")
        } catch {
            // Keep the staging directory on a promotion failure; never delete a possibly
            // relocated original as part of error cleanup.
            finish(item, status: "保存を完了できませんでした。一時データは残しています。")
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.active else { return }
        item.destination?.cleanup()
        item.destination = nil
        finish(item, status: item.status == "取り消し中" ? "取り消しました" : "ダウンロードに失敗しました。元のリンクから試してください。")
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(NavigationPolicy.allows(request.url, isMainFrame: true) ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func showInFinder(_ item: DownloadItem) {
        guard !item.active, let destination = item.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.completed ? destination.url : destination.directory])
    }

    private func finish(_ item: DownloadItem, status: String) {
        notice = nil
        item.active = false
        item.choosingDestination = false
        item.status = status
        item.observation = nil
        item.download?.delegate = nil
        item.download = nil
        checkQuit()
    }

    private func checkQuit() {
        if quitAfterCancelling && !hasActive {
            quitAfterCancelling = false
            // Let the original applicationShouldTerminate call return first.
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
