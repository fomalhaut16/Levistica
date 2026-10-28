import Foundation
import Darwin
import SQLite3

struct Bookmark: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
    var folders: [String] = []
}

// Synchronous, small transactions owned by BookmarkLibrary on MainActor.
final class BookmarkStore {
    enum Failure: LocalizedError {
        case unavailable, invalidData, newerVersion, limit
        var errorDescription: String? {
            switch self {
            case .unavailable: "ブックマークを保存できませんでした。保存先と空き容量を確認してください。"
            case .invalidData: "ブックマークを読み込めませんでした。保存データを残しています。"
            case .newerVersion: "新しい形式のブックマークです。対応する版のLevisticaで開いてください。"
            case .limit: "ブックマークは1000件まで保存できます。不要な項目を削除してから追加してください。"
            }
        }
    }
    private var hasFolders = false
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL?) throws {
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                                    attributes: [.posixPermissions: 0o600]) else { throw Failure.unavailable }
            }
        }
        guard sqlite3_open_v2(fileURL?.path ?? ":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil
            throw Failure.unavailable
        }
        do {
            sqlite3_busy_timeout(db, 100)
            let number: Int32
            do {
                let version = try statement("PRAGMA user_version")
                defer { sqlite3_finalize(version) }
                guard sqlite3_step(version) == SQLITE_ROW else { throw Failure.invalidData }
                number = sqlite3_column_int(version, 0)
            }
            guard number == 0 || number == 1 || number == 2 else { throw Failure.newerVersion }
            if number == 0 {
                try transaction {
                    try createTable("bookmarks")
                    try execute("PRAGMA user_version=2")
                }
            } else if number == 1 {
                _ = try load() // Validate every old record before backing up or migrating.
                if let fileURL { try backupLegacy(at: fileURL) }
                try transaction {
                    _ = try load()
                    try createTable("bookmarks_v2")
                    try execute("INSERT INTO bookmarks_v2 SELECT id,url,title,created,'[]' FROM bookmarks")
                    try execute("DROP TABLE bookmarks")
                    try execute("ALTER TABLE bookmarks_v2 RENAME TO bookmarks")
                    try execute("PRAGMA user_version=2")
                }
            }
            hasFolders = true

        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close(db) } }

    func load() throws -> [Bookmark] {
        let row = try statement("SELECT id,url,title,\(hasFolders ? "folder_path" : "'[]'") FROM bookmarks ORDER BY created DESC,id LIMIT 1001")
        defer { sqlite3_finalize(row) }
        var result: [Bookmark] = []
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            guard result.count < 1000, let rawID = text(row, 0, maxBytes: 36), let id = UUID(uuidString: rawID),
                  let rawURL = text(row, 1, maxBytes: 16_384), let url = URL(string: rawURL),
                  url.absoluteString == rawURL, SessionStore.persistableURL(url) == url,
                  let title = text(row, 2, maxBytes: 2048), Self.validTitle(title),
                  let rawFolders = text(row, 3, maxBytes: 8192),
                  let folders = try? JSONDecoder().decode([String].self, from: Data(rawFolders.utf8)),
                  Self.validFolders(folders), try Self.encodedFolders(folders) == rawFolders else { throw Failure.invalidData }
            result.append(Bookmark(id: id, url: url, title: title, folders: folders))
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw Failure.unavailable }
        return result
    }

    @discardableResult
    func add(url: URL, title: String, id: UUID = UUID(), folders: [String] = []) throws -> UUID {
        guard SessionStore.persistableURL(url) == url, Self.validTitle(title), Self.validFolders(folders) else { throw Failure.invalidData }
        var selected = id
        try transaction {
            let items = try load()
            if let existing = items.first(where: { $0.url == url && $0.folders == folders }) { selected = existing.id; return }
            guard items.count < 1000 else { throw Failure.limit }
            let row = try statement("INSERT INTO bookmarks (id,url,title,created,folder_path) VALUES (?,?,?,?,?)")
            defer { sqlite3_finalize(row) }
            try bind(id.uuidString, row, 1); try bind(url.absoluteString, row, 2); try bind(title, row, 3); try bind(Self.encodedFolders(folders), row, 5)
            guard sqlite3_bind_double(row, 4, Date().timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
        }
        return selected
    }

    func importEntries(_ entries: [ImportedBookmark]) throws -> Int {
        guard entries.count <= 1000 else { throw Failure.limit }
        var count = 0
        try transaction {
            var current = try load()
            let importedAt = Date().timeIntervalSince1970
            for entry in entries {
                guard SessionStore.persistableURL(entry.url) == entry.url,
                      Self.validTitle(entry.title), Self.validFolders(entry.folders) else { throw Failure.invalidData }
                if current.contains(where: { $0.url == entry.url && $0.folders == entry.folders }) { continue }
                guard current.count < 1000 else { throw Failure.limit }
                let item = Bookmark(id: UUID(), url: entry.url, title: entry.title, folders: entry.folders)
                let row = try statement("INSERT INTO bookmarks (id,url,title,created,folder_path) VALUES (?,?,?,?,?)")
                defer { sqlite3_finalize(row) }
                try bind(item.id.uuidString, row, 1); try bind(item.url.absoluteString, row, 2)
                try bind(item.title, row, 3); try bind(Self.encodedFolders(item.folders), row, 5)
                guard sqlite3_bind_double(row, 4, importedAt - Double(count) * 0.001) == SQLITE_OK,
                      sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
                current.append(item); count += 1
            }
        }
        return count
    }

    static func validFolders(_ folders: [String]) -> Bool {
        folders.count <= 32 && folders.allSatisfy { validTitle($0) && $0.utf16.count <= 256 }
            && ((try? JSONEncoder().encode(folders).count) ?? Int.max) <= 8192
    }

    static func encodedFolders(_ folders: [String]) throws -> String {
        guard validFolders(folders), let value = String(data: try JSONEncoder().encode(folders), encoding: .utf8) else {
            throw Failure.invalidData
        }
        return value
    }

    private func createTable(_ name: String) throws {
        // Internal fixed table names only, never file or bookmark contents.
        try execute("CREATE TABLE \(name) (id TEXT PRIMARY KEY NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, created REAL NOT NULL, folder_path TEXT NOT NULL DEFAULT '[]', UNIQUE(url,folder_path))")
    }

    private func backupLegacy(at file: URL) throws {
        let backup = file.deletingLastPathComponent().appendingPathComponent("bookmarks-v1-" + UUID().uuidString + ".sqlite3")
        let descriptor = backup.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw Failure.unavailable }
        Darwin.close(descriptor)
        var copy: OpaquePointer?
        guard sqlite3_open_v2(backup.path, &copy, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let copy else {
            if let copy { sqlite3_close(copy) }; throw Failure.unavailable
        }
        defer { sqlite3_close(copy) }
        guard let handle = sqlite3_backup_init(copy, "main", db, "main") else { throw Failure.unavailable }
        let result = sqlite3_backup_step(handle, -1)
        let finished = sqlite3_backup_finish(handle)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw Failure.unavailable }
    }

    func rename(_ id: UUID, title: String) throws {
        guard Self.validTitle(title) else { throw Failure.invalidData }
        try transaction {
            _ = try load() // Refuse mutations if any existing record is invalid.
            let row = try statement("UPDATE bookmarks SET title=? WHERE id=?")
            defer { sqlite3_finalize(row) }
            try bind(title, row, 1); try bind(id.uuidString, row, 2)
            guard sqlite3_step(row) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw Failure.unavailable }
        }
    }

    func remove(_ id: UUID) throws {
        try transaction {
            _ = try load()
            let row = try statement("DELETE FROM bookmarks WHERE id=?")
            defer { sqlite3_finalize(row) }
            try bind(id.uuidString, row, 1)
            guard sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
        }
    }

    static func validTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf16.count <= 512
            && title.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw Failure.unavailable }
        return result
    }
    private func bind(_ value: String, _ row: OpaquePointer, _ index: Int32) throws {
        guard value.withCString({ sqlite3_bind_text(row, index, $0, -1, transient) }) == SQLITE_OK else { throw Failure.unavailable }
    }
    private func text(_ row: OpaquePointer, _ index: Int32, maxBytes: Int) -> String? {
        let count = Int(sqlite3_column_bytes(row, index))
        guard count <= maxBytes, let bytes = sqlite3_column_text(row, index) else { return nil }
        return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
    }
}
