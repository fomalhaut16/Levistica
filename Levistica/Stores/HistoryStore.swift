import Foundation
import SQLite3

struct HistoryEntry: Identifiable, Sendable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let visited: Date
}

struct HistoryPreferences: Equatable, Sendable {
    var recordingEnabled = true
    var retentionDays = 90
    static let allowedDays = [1, 7, 30, 90, 365]
}

// SQLite and file I/O stay on this actor. Only bounded value snapshots reach the UI.
actor HistoryStore {
    private let fileURL: URL?
    private var database: HistoryDatabase?
    init(fileURL: URL?) { self.fileURL = fileURL }

    private func source() throws -> HistoryDatabase {
        if let database { return database }
        let opened = try HistoryDatabase(fileURL: fileURL)
        database = opened
        return opened
    }

    func record(url: URL, title: String, now: Date = Date()) throws {
        guard SessionStore.persistableURL(url) == url else { return }
        let storedTitle = Self.boundedTitle(title, url: url)
        guard BookmarkStore.validTitle(storedTitle), now.timeIntervalSince1970.isFinite else { throw HistoryDatabase.Failure.invalidData }
        let db = try source()
        try db.transaction {
            guard try db.preferences().recordingEnabled else { return }
            let row = try db.statement("INSERT INTO history VALUES (?,?,?) ON CONFLICT(url) DO UPDATE SET title=excluded.title,visited=excluded.visited")
            defer { sqlite3_finalize(row) }
            try db.bind(url.absoluteString, row, 1)
            try db.bind(storedTitle, row, 2)
            guard sqlite3_bind_double(row, 3, now.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(row) == SQLITE_DONE else { throw HistoryDatabase.Failure.unavailable }
            try db.prune(now: now)
        }
    }

    private static func boundedTitle(_ title: String, url: URL) -> String {
        let value = String(decoding: title.utf16.prefix(512), as: UTF16.self)
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? String((url.host ?? "ページ").prefix(128)) : value
    }

    func updateTitle(url: URL, title: String, visited: Date) throws {
        guard SessionStore.persistableURL(url) == url else { return }
        let value = Self.boundedTitle(title, url: url)
        guard BookmarkStore.validTitle(value) else { throw HistoryDatabase.Failure.invalidData }
        let db = try source()
        try db.transaction {
            guard try db.preferences().recordingEnabled else { return }
            let row = try db.statement("UPDATE history SET title=? WHERE url=? AND visited=?")
            defer { sqlite3_finalize(row) }
            try db.bind(value, row, 1); try db.bind(url.absoluteString, row, 2)
            guard sqlite3_bind_double(row, 3, visited.timeIntervalSince1970) == SQLITE_OK,
                  sqlite3_step(row) == SQLITE_DONE else { throw HistoryDatabase.Failure.unavailable }
        }
    }

    func search(_ query: String = "", now: Date = Date()) throws -> [HistoryEntry] {
        let db = try source()
        try db.transaction { try db.prune(now: now) }
        let row = try db.statement("SELECT url,title,visited FROM history WHERE instr(lower(title),lower(?))>0 OR instr(lower(url),lower(?))>0 ORDER BY visited DESC,url LIMIT 200")
        defer { sqlite3_finalize(row) }
        let bounded = String(query.prefix(512))
        try db.bind(bounded, row, 1); try db.bind(bounded, row, 2)
        var result: [HistoryEntry] = []
        var step = sqlite3_step(row)
        while step == SQLITE_ROW {
            result.append(try db.entry(row))
            step = sqlite3_step(row)
        }
        guard step == SQLITE_DONE else { throw HistoryDatabase.Failure.unavailable }
        return result
    }

    func preferences() throws -> HistoryPreferences { try source().preferences() }

    func setPreferences(_ value: HistoryPreferences, now: Date = Date()) throws {
        guard HistoryPreferences.allowedDays.contains(value.retentionDays) else { throw HistoryDatabase.Failure.invalidData }
        let db = try source()
        try db.transaction {
            _ = try db.preferences()
            let row = try db.statement("UPDATE history_preferences SET enabled=?,days=? WHERE id=1")
            defer { sqlite3_finalize(row) }
            guard sqlite3_bind_int(row, 1, value.recordingEnabled ? 1 : 0) == SQLITE_OK,
                  sqlite3_bind_int(row, 2, Int32(value.retentionDays)) == SQLITE_OK,
                  sqlite3_step(row) == SQLITE_DONE else { throw HistoryDatabase.Failure.unavailable }
            try db.prune(now: now)
        }
    }

    func remove(_ url: URL) throws {
        let db = try source()
        try db.transaction {
            let row = try db.statement("DELETE FROM history WHERE url=?")
            defer { sqlite3_finalize(row) }
            try db.bind(url.absoluteString, row, 1)
            guard sqlite3_step(row) == SQLITE_DONE else { throw HistoryDatabase.Failure.unavailable }
        }
    }

    func clear() throws {
        let db = try source()
        try db.transaction { try db.execute("DELETE FROM history") }
    }
}

// This non-Sendable handle never leaves its owning HistoryStore actor.
private final class HistoryDatabase {
    enum Failure: LocalizedError {
        case unavailable, invalidData, newerVersion
        var errorDescription: String? {
            switch self {
            case .unavailable: "閲覧履歴を読み書きできませんでした。保存先と空き容量を確認してください。"
            case .invalidData: "閲覧履歴を読み込めませんでした。保存データを残しています。"
            case .newerVersion: "新しい形式の閲覧履歴です。対応する版のLevisticaで開いてください。"
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
            if let db { sqlite3_close(db) }; db = nil; throw Failure.unavailable
        }
        do {
            sqlite3_busy_timeout(db, 100)
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw Failure.invalidData }
            let number = sqlite3_column_int(version, 0)
            guard (0...2).contains(number) else { throw Failure.newerVersion }
            if number == 0 {
                try transaction {
                    try execute("CREATE TABLE history (url TEXT PRIMARY KEY NOT NULL,title TEXT NOT NULL,visited REAL NOT NULL)")
                    try execute("CREATE INDEX history_visited ON history(visited DESC)")
                    try execute("PRAGMA user_version=1")
                }
            }
            // Validate existing rows before any retention or mutation can change them.
            let rows = try statement("SELECT url,title,visited FROM history LIMIT 10001")
            defer { sqlite3_finalize(rows) }
            var count = 0
            var step = sqlite3_step(rows)
            while step == SQLITE_ROW {
                count += 1
                guard count <= 10_000 else { throw Failure.invalidData }
                _ = try entry(rows)
                step = sqlite3_step(rows)
            }
            guard step == SQLITE_DONE else { throw Failure.invalidData }
            if number < 2 {
                try transaction {
                    try execute("CREATE TABLE history_preferences (id INTEGER PRIMARY KEY CHECK(id=1),enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),days INTEGER NOT NULL CHECK(days IN (1,7,30,90,365)))")
                    try execute("INSERT INTO history_preferences VALUES(1,1,90)")
                    try execute("PRAGMA user_version=2")
                }
            }
            _ = try preferences()
            try execute("PRAGMA secure_delete=ON")
        } catch { sqlite3_close(db); db = nil; throw error }
    }

    deinit { if let db { sqlite3_close(db) } }

    func entry(_ row: OpaquePointer) throws -> HistoryEntry {
        func text(_ index: Int32, limit: Int) -> String? {
            let size = Int(sqlite3_column_bytes(row, index))
            guard size <= limit, let bytes = sqlite3_column_text(row, index) else { return nil }
            return String(data: Data(bytes: bytes, count: size), encoding: .utf8)
        }
        let timestamp = sqlite3_column_double(row, 2)
        guard let raw = text(0, limit: 16_384), let url = URL(string: raw), raw == url.absoluteString,
              SessionStore.persistableURL(url) == url,
              let title = text(1, limit: 2048), BookmarkStore.validTitle(title),
              [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 2)), timestamp.isFinite else { throw Failure.invalidData }
        return HistoryEntry(url: url, title: title, visited: Date(timeIntervalSince1970: timestamp))
    }

    func preferences() throws -> HistoryPreferences {
        let row = try statement("SELECT id,enabled,days FROM history_preferences")
        defer { sqlite3_finalize(row) }
        guard sqlite3_step(row) == SQLITE_ROW,
              sqlite3_column_type(row, 0) == SQLITE_INTEGER, sqlite3_column_int64(row, 0) == 1,
              sqlite3_column_type(row, 1) == SQLITE_INTEGER, sqlite3_column_type(row, 2) == SQLITE_INTEGER else { throw Failure.invalidData }
        let enabled = sqlite3_column_int64(row, 1)
        let days = Int(sqlite3_column_int64(row, 2))
        guard [0,1].contains(enabled), HistoryPreferences.allowedDays.contains(days),
              sqlite3_step(row) == SQLITE_DONE else { throw Failure.invalidData }
        return HistoryPreferences(recordingEnabled: enabled == 1, retentionDays: days)
    }

    func prune(now: Date) throws {
        let row = try statement("DELETE FROM history WHERE visited<?")
        defer { sqlite3_finalize(row) }
        guard sqlite3_bind_double(row, 1, now.addingTimeInterval(-Double(try preferences().retentionDays) * 86400).timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
        try execute("DELETE FROM history WHERE url IN (SELECT url FROM history ORDER BY visited DESC,url LIMIT -1 OFFSET 10000)")
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func statement(_ sql: String) throws -> OpaquePointer {
        var row: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &row, nil) == SQLITE_OK, let row else { throw Failure.unavailable }
        return row
    }
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }
    func bind(_ text: String, _ row: OpaquePointer, _ index: Int32) throws {
        guard text.withCString({ sqlite3_bind_text(row, index, $0, -1, transient) }) == SQLITE_OK else { throw Failure.unavailable }
    }
}
