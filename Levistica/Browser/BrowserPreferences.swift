import Foundation
import Observation

@MainActor @Observable
final class BrowserPreferences {
    private struct Saved: Codable { let version: Int; let newTabURL: String? }
    private let fileURL: URL?
    private(set) var newTabURL: URL?
    private(set) var canSave = true
    private(set) var notice: String?
    var isPersistent: Bool { fileURL != nil }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        do {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= 16_384 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL))
            guard saved.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            if let value = saved.newTabURL {
                let url = try Self.pageURL(value)
                guard url?.absoluteString == value else { throw CocoaError(.fileReadCorruptFile) }
                newTabURL = url
            }
        } catch {
            canSave = false
            notice = "新しいタブの設定を読み込めませんでした。元の保存ファイルを残しています。"
        }
    }

    static func pageURL(_ input: String) throws -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard !value.contains(where: \.isWhitespace),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let normalized = value.contains("://") ? value : "https://" + value
        guard let url = URL(string: normalized), url.absoluteString.utf8.count <= 4096,
              SessionStore.persistableURL(url) == url,
              NavigationPolicy.allows(url, isMainFrame: true),
              try AddressResolver.resolve(normalized) == url else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return url
    }

    @discardableResult
    func saveNewTabPage(_ input: String) -> Bool {
        guard canSave else { return false }
        let page: URL?
        do { page = try Self.pageURL(input) }
        catch {
            notice = "HTTPまたはHTTPSのURLを入力してください。空欄にすると空白ページになります。"
            return false
        }
        do {
            if let fileURL {
                let manager = FileManager.default
                try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
                if let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
                   attributes[.type] as? FileAttributeType != .typeRegular { throw CocoaError(.fileWriteUnknown) }
                let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".browser-preferences-" + UUID().uuidString)
                defer { try? manager.removeItem(at: temporary) }
                let data = try JSONEncoder().encode(Saved(version: 1, newTabURL: page?.absoluteString))
                guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if manager.fileExists(atPath: fileURL.path) {
                    _ = try manager.replaceItemAt(fileURL, withItemAt: temporary, options: .usingNewMetadataOnly)
                } else { try manager.moveItem(at: temporary, to: fileURL) }
            }
            newTabURL = page
            notice = "設定を保存しました。次に追加するタブから適用します。"
            return true
        } catch {
            notice = "設定を保存できませんでした。これまでの設定を使います。"
            return false
        }
    }
}
