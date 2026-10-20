import Foundation
import SQLite3

struct SavedTab: Equatable {
    let id: UUID
    let title: String
    let url: URL?
    let mayReload: Bool
}

struct SavedSession: Equatable {
    let tabs: [SavedTab]
    let selectedID: UUID
    let wasRunning: Bool
}

// Owned synchronously by BrowserSession on MainActor; no concurrent callers.
final class SessionStore {
    enum Failure: Error { case unavailable, invalidData, newerVersion }
    private var database: OpaquePointer?
    private var lastSaved: SavedSession?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(fileURL: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.unavailable
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw Failure.unavailable
        }
        do {
            sqlite3_busy_timeout(database, 1000)
            let version = try statement("PRAGMA user_version")
            defer { sqlite3_finalize(version) }
            guard sqlite3_step(version) == SQLITE_ROW else { throw Failure.invalidData }
            let number = sqlite3_column_int(version, 0)
            guard number <= 1 else { throw Failure.newerVersion }
            if number == 0 {
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL)")
                    try execute("CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL)")
                    try execute("PRAGMA user_version=1")
                    try execute("COMMIT")
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func load() throws -> SavedSession? {
        let rows = try statement("SELECT id, position, title, url, may_reload FROM session_tabs ORDER BY position")
        defer { sqlite3_finalize(rows) }
        var tabs: [SavedTab] = []
        var ids = Set<UUID>()
        var result = sqlite3_step(rows)
        while result == SQLITE_ROW {
            guard tabs.count < 1000, let rawID = text(rows, 0), let id = UUID(uuidString: rawID),
                  ids.insert(id).inserted, sqlite3_column_int(rows, 1) == tabs.count,
                  let title = text(rows, 2), title.count <= 512 else { throw Failure.invalidData }
            let rawURL = text(rows, 3)
            let url = rawURL.flatMap(URL.init(string:))
            if rawURL != nil && (url == nil || Self.persistableURL(url) != url) { throw Failure.invalidData }
            let mayReload = sqlite3_column_int(rows, 4)
            guard mayReload == 0 || mayReload == 1 else { throw Failure.invalidData }
            tabs.append(SavedTab(id: id, title: title, url: url, mayReload: mayReload == 1))
            result = sqlite3_step(rows)
        }
        guard result == SQLITE_DONE else { throw Failure.unavailable }
        let meta = try statement("SELECT selected_id, was_running FROM session_meta WHERE id=1")
        defer { sqlite3_finalize(meta) }
        let metaResult = sqlite3_step(meta)
        if tabs.isEmpty && metaResult == SQLITE_DONE { return nil }
        guard !tabs.isEmpty, metaResult == SQLITE_ROW, let rawSelected = text(meta, 0),
              let selected = UUID(uuidString: rawSelected), ids.contains(selected) else { throw Failure.invalidData }
        let running = sqlite3_column_int(meta, 1)
        guard running == 0 || running == 1 else { throw Failure.invalidData }
        return SavedSession(tabs: tabs, selectedID: selected, wasRunning: running == 1)
    }

    func save(_ session: SavedSession) throws {
        if lastSaved == session { return }
        guard !session.tabs.isEmpty, session.tabs.count <= 1000,
              Set(session.tabs.map(\.id)).count == session.tabs.count,
              session.tabs.contains(where: { $0.id == session.selectedID }) else { throw Failure.invalidData }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM session_tabs")
            for (index, tab) in session.tabs.enumerated() {
                let row = try statement("INSERT INTO session_tabs VALUES (?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(row) }
                try bind(tab.id.uuidString, to: 1, in: row)
                guard sqlite3_bind_int(row, 2, Int32(index)) == SQLITE_OK else { throw Failure.unavailable }
                try bind(String(tab.title.prefix(512)), to: 3, in: row)
                try bind(Self.persistableURL(tab.url)?.absoluteString, to: 4, in: row)
                guard sqlite3_bind_int(row, 5, tab.mayReload ? 1 : 0) == SQLITE_OK,
                      sqlite3_step(row) == SQLITE_DONE else { throw Failure.unavailable }
            }
            let meta = try statement("INSERT OR REPLACE INTO session_meta VALUES (1, ?, ?)")
            defer { sqlite3_finalize(meta) }
            try bind(session.selectedID.uuidString, to: 1, in: meta)
            guard sqlite3_bind_int(meta, 2, session.wasRunning ? 1 : 0) == SQLITE_OK,
                  sqlite3_step(meta) == SQLITE_DONE else { throw Failure.unavailable }
            try execute("COMMIT")
            lastSaved = session
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func persistableURL(_ url: URL?) -> URL? {
        guard let url, url.absoluteString.utf8.count <= 16_384,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil else { return nil }
        // Best-effort exclusion of recognizable authentication callbacks, not a guarantee
        // that arbitrary URL parameters contain no secrets. The DB remains private data.
        let sensitive: Set<String> = ["code", "access_token", "id_token", "token", "oauth_token", "session_token", "password", "ticket", "code_challenge"]
        let keys = Set((parts.queryItems ?? []).map { $0.name.lowercased() })
        if !sensitive.isDisjoint(with: keys) || (keys.contains("client_id") && keys.contains("redirect_uri")) { return nil }
        if let fragment = parts.fragment,
           let items = URLComponents(string: "https://local.invalid/?" + fragment)?.queryItems,
           items.contains(where: { sensitive.contains($0.name.lowercased()) }) { return nil }
        return url
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw Failure.unavailable
        }
        return prepared
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure.unavailable }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        let result = value.map { string in
            string.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        } ?? sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else { throw Failure.unavailable }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }
}
