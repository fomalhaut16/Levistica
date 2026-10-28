import Foundation

struct ImportedBookmark: Equatable, Sendable {
    let url: URL
    let title: String
    let folders: [String]
}

struct BookmarkImportPreview: Sendable {
    let entries: [ImportedBookmark]
    let rejectedCount: Int
    let repeatedCount: Int
    let emptyFolderCount: Int
}

enum BookmarkHTMLImport {
    static let maximumBytes = 8 * 1024 * 1024
    enum Failure: LocalizedError {
        case format, tooLarge, tooMany, folders, ambiguousFolders
        var errorDescription: String? {
            switch self {
            case .format: "UTF-8のブックマークHTMLを選んでください。Chrome等で書き出したファイルを使えます。"
            case .tooLarge: "8MiB以下のブックマークHTMLを選んでください。"
            case .tooMany: "取り込めるブックマークは1000件までです。ファイルを分けて整理してください。"
            case .ambiguousFolders: "同じ場所に同名のフォルダーがあります。元のブラウザで名前を分けてから取り込んでください。"
            case .folders: "フォルダーの階層が深すぎるか、名前が長すぎます。元のブラウザで整理してください。"
            }
        }
    }

    static func read(_ url: URL) throws -> BookmarkImportPreview {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.format }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= maximumBytes else { throw Failure.tooLarge }
            data.append(chunk)
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> BookmarkImportPreview {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        guard let html = String(data: data, encoding: .utf8),
              html.prefix(4096).localizedCaseInsensitiveContains("<!DOCTYPE NETSCAPE-Bookmark-file-1>"),
              !html.localizedCaseInsensitiveContains("<!ENTITY") else { throw Failure.format }
        // This parser builds a local tree only. It never renders HTML, runs JS,
        // resolves external entities, or follows any bookmark URL.
        let document: XMLDocument
        do { document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) }
        catch { throw Failure.format }
        var entries: [ImportedBookmark] = []
        var rejected = 0, repeated = 0, anchors = 0, nodes = 0, emptyFolders = 0
        var seen = Set<String>()
        var folderPaths = Set<String>()
        func visit(_ children: [XMLNode], folders: [String], inList: Bool, depth: Int) throws -> String? {
            guard depth <= 128 else { throw Failure.folders }
            var pendingFolder: String?
            for node in children {
                nodes += 1
                guard nodes <= 100_000 else { throw Failure.tooLarge }
                guard let element = node as? XMLElement else { continue }
                let name = element.localName?.lowercased() ?? element.name?.lowercased() ?? ""
                if ["script", "style"].contains(name) { continue }
                if name == "h3", inList {
                    guard pendingFolder == nil else { throw Failure.format }
                    let title = normalized(element.stringValue ?? "")
                    guard !title.isEmpty, title.utf16.count <= 256 else { throw Failure.folders }
                    pendingFolder = title
                } else if name == "dl" {
                    let path = folders + (pendingFolder.map { [$0] } ?? [])
                    guard BookmarkStore.validFolders(path) else { throw Failure.folders }
                    if pendingFolder != nil {
                        guard folderPaths.insert(try BookmarkStore.encodedFolders(path)).inserted else { throw Failure.ambiguousFolders }
                    }
                    let count = anchors
                    guard try visit(element.children ?? [], folders: path, inList: true, depth: depth + 1) == nil else { throw Failure.format }
                    if pendingFolder != nil && anchors == count { emptyFolders += 1 }
                    pendingFolder = nil
                } else if name == "a", inList {
                    guard pendingFolder == nil else { throw Failure.format }
                    anchors += 1
                    guard anchors <= 10_000 else { throw Failure.tooMany }
                    guard let raw = element.attribute(forName: "href")?.stringValue,
                          let url = URL(string: raw), url.absoluteString == raw,
                          SessionStore.persistableURL(url) == url else { rejected += 1; continue }
                    let key = url.absoluteString + "\n" + (try BookmarkStore.encodedFolders(folders))
                    let name = normalized(element.stringValue ?? "")
                    let title = name.isEmpty ? (url.host ?? "ブックマーク") : name
                    guard BookmarkStore.validTitle(title) else { rejected += 1; continue }
                    guard seen.insert(key).inserted else { repeated += 1; continue }
                    entries.append(ImportedBookmark(url: url, title: title, folders: folders))
                    guard entries.count <= 1000 else { throw Failure.tooMany }
                } else {
                    let before = anchors
                    let childFolder = try visit(element.children ?? [], folders: folders, inList: inList, depth: depth + 1)
                    guard pendingFolder == nil || anchors == before else { throw Failure.format }
                    if let childFolder {
                        guard pendingFolder == nil else { throw Failure.format }
                        pendingFolder = childFolder
                    }
                }
            }
            return pendingFolder
        }
        guard try visit(document.children ?? [], folders: [], inList: false, depth: 0) == nil else { throw Failure.format }
        return BookmarkImportPreview(entries: entries, rejectedCount: rejected,
                                     repeatedCount: repeated, emptyFolderCount: emptyFolders)
    }

    private static func normalized(_ value: String) -> String {
        value.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
