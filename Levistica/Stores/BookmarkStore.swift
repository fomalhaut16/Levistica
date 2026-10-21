import Foundation
import SQLite3

struct Bookmark: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let title: String
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
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw Failure.invalidData }
            let number = sqlite3_column_int(version, 0)
            guard number == 0 || number == 1 else { throw Failure.newerVersion }
            if number == 0 {
                try transaction {
                    try execute("CREATE TABLE bookmarks (id TEXT PRIMARY KEY NOT NULL, url TEXT UNIQUE NOT NULL, title TEXT NOT NULL, created REAL NOT NULL)")
                    try execute("PRAGMA user_version=1")
                }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close(db) } }

    func load() throws -> [Bookmark] {
        let row = try statement("SELECT id,url,title FROM bookmarks ORDER BY created DESC,id LIMIT 1001")
        defer { sqlite3_finalize(row) }
        var result: [Bookmark] = []
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            guard result.count < 1000, let rawID = text(row, 0, maxBytes: 36), let id = UUID(uuidString: rawID),
                  let rawURL = text(row, 1, maxBytes: 16_384), let url = URL(string: rawURL),
                  url.absoluteString == rawURL, SessionStore.persistableURL(url) == url,
                  let title = text(row, 2, maxBytes: 2048), Self.validTitle(title) else { throw Failure.invalidData }
            result.append(Bookmark(id: id, url: url, title: title))
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw Failure.unavailable }
        return result
    }

    @discardableResult
    func add(url: URL, title: String, id: UUID = UUID()) throws -> UUID {
        guard SessionStore.persistableURL(url) == url, Self.validTitle(title) else { throw Failure.invalidData }
        var selected = id
        try transaction {
            let items = try load()
            if let existing = items.first(where: { $0.url == url }) { selected = existing.id; return }
            guard items.count < 1000 else { throw Failure.limit }
            let row = try statement("INSERT INTO bookmarks VALUES (?,?,?,?)")
            defer { sqlite3_finalize(row) }
            try bind(id.uuidString, row, 1); try bind(url.absoluteString, row, 2); try bind(title, row, 3)
            guard sqlite3_bind_double(row, 4, Date().timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
        }
        return selected
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
