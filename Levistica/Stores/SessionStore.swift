import Foundation
import SQLite3

struct SavedTab: Equatable {
    enum Kind: String { case web, localPDF }
    let kind: Kind
    let id: UUID
    let title: String
    let url: URL?
    let mayReload: Bool
    let isKept: Bool
    let isSleeping: Bool
    init(id: UUID, title: String, url: URL?, mayReload: Bool, kind: Kind = .web, isKept: Bool = false, isSleeping: Bool = false) {
        self.id = id; self.title = title; self.url = url; self.mayReload = mayReload; self.kind = kind
        self.isKept = isKept; self.isSleeping = isSleeping
    }
}

struct SavedSession: Equatable {
    let tabs: [SavedTab]
    let selectedID: UUID
    let wasRunning: Bool
}

// Owned synchronously by BrowserSession on MainActor; no concurrent callers.
final class SessionStore {
    static let maximumTabCount = 1000
    enum Failure: Error { case unavailable, invalidData, newerVersion }
    private var database: OpaquePointer?
    private let fileURL: URL
    var dataFileURL: URL { fileURL }
    var backupURL: URL { fileURL.appendingPathExtension("backup") }
    private var lastSaved: SavedSession?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    convenience init(fileURL: URL) throws {
        try self.init(fileURL: fileURL, readOnly: false)
    }

    private init(fileURL: URL, readOnly: Bool) throws {
        self.fileURL = fileURL
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: fileURL.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidData }
        } else if readOnly {
            throw Failure.unavailable
        }
        if !readOnly {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw Failure.unavailable
                }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        // Verified snapshots are complete files replaced atomically, never edited in place.
        // Immutable reads also handle a copied WAL-mode header without touching sidecars.
        var filename = fileURL.path
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        if readOnly {
            var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components?.string else { throw Failure.invalidData }
            filename = uri
            flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        }
        guard sqlite3_open_v2(filename, &database, flags, nil) == SQLITE_OK else {
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
            guard number <= 3 else { throw Failure.newerVersion }
            if readOnly {
                guard number == 3 else { throw Failure.invalidData }
                return
            }
            if number < 3 {
                // All required schema steps and the version advance must commit
                // together, so a later failure cannot leave a partial upgrade.
                try execute("BEGIN IMMEDIATE")
                do {
                    if number == 0 {
                        try execute("CREATE TABLE session_tabs (id TEXT PRIMARY KEY NOT NULL, position INTEGER UNIQUE NOT NULL, title TEXT NOT NULL, url TEXT, may_reload INTEGER NOT NULL)")
                        try execute("CREATE TABLE session_meta (id INTEGER PRIMARY KEY CHECK(id=1), selected_id TEXT NOT NULL, was_running INTEGER NOT NULL)")
                    }
                    if number < 2 {
                        try execute("ALTER TABLE session_tabs ADD COLUMN kind TEXT NOT NULL DEFAULT 'web'")
                    }
                    try execute("ALTER TABLE session_tabs ADD COLUMN is_kept INTEGER NOT NULL DEFAULT 0")
                    try execute("ALTER TABLE session_tabs ADD COLUMN is_sleeping INTEGER NOT NULL DEFAULT 0")
                    // Invalid legacy records must roll back the schema changes
                    // too, before a caller attempts to restore the session.
                    _ = try load()
                    try execute("PRAGMA user_version=3")
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
        let rows = try statement("SELECT id, position, title, url, may_reload, kind, is_kept, is_sleeping FROM session_tabs ORDER BY position")
        defer { sqlite3_finalize(rows) }
        var tabs: [SavedTab] = []
        var ids = Set<UUID>()
        var result = sqlite3_step(rows)
        while result == SQLITE_ROW {
            guard tabs.count < Self.maximumTabCount, let rawID = try text(rows, 0), rawID.utf8.count == 36,
                  let id = UUID(uuidString: rawID),
                  ids.insert(id).inserted, sqlite3_column_type(rows, 1) == SQLITE_INTEGER,
                  sqlite3_column_int64(rows, 1) == Int64(tabs.count),
                  let title = try text(rows, 2), title.count <= 512 else { throw Failure.invalidData }
            let rawURL = try text(rows, 3)
            let url = rawURL.flatMap(URL.init(string:))
            if rawURL != nil && (url == nil || Self.persistableURL(url) != url) { throw Failure.invalidData }
            guard sqlite3_column_type(rows, 4) == SQLITE_INTEGER else { throw Failure.invalidData }
            let mayReload = sqlite3_column_int64(rows, 4)
            guard mayReload == 0 || mayReload == 1 else { throw Failure.invalidData }
            guard let rawKind = try text(rows, 5), let kind = SavedTab.Kind(rawValue: rawKind),
                  kind != .localPDF || (url == nil && mayReload == 0) else { throw Failure.invalidData }
            guard sqlite3_column_type(rows, 6) == SQLITE_INTEGER,
                  sqlite3_column_type(rows, 7) == SQLITE_INTEGER else { throw Failure.invalidData }
            let kept = sqlite3_column_int64(rows, 6)
            let sleeping = sqlite3_column_int64(rows, 7)
            guard (kept == 0 || kept == 1), (sleeping == 0 || sleeping == 1),
                  sleeping == 0 || (kind == .web && url != nil && mayReload == 1) else { throw Failure.invalidData }
            tabs.append(SavedTab(id: id, title: title, url: url, mayReload: mayReload == 1, kind: kind,
                                 isKept: kept == 1, isSleeping: sleeping == 1))
            result = sqlite3_step(rows)
        }
        guard result == SQLITE_DONE else { throw Failure.unavailable }
        let meta = try statement("SELECT selected_id, was_running FROM session_meta WHERE id=1")
        defer { sqlite3_finalize(meta) }
        let metaResult = sqlite3_step(meta)
        if tabs.isEmpty && metaResult == SQLITE_DONE { return nil }
        guard !tabs.isEmpty, metaResult == SQLITE_ROW, let rawSelected = try text(meta, 0), rawSelected.utf8.count == 36,
              let selected = UUID(uuidString: rawSelected), ids.contains(selected) else { throw Failure.invalidData }
        guard sqlite3_column_type(meta, 1) == SQLITE_INTEGER else { throw Failure.invalidData }
        let running = sqlite3_column_int64(meta, 1)
        guard running == 0 || running == 1 else { throw Failure.invalidData }
        return SavedSession(tabs: tabs, selectedID: selected, wasRunning: running == 1)
    }

    func save(_ session: SavedSession) throws {
        if lastSaved == session { return }
        guard !session.tabs.isEmpty, session.tabs.count <= Self.maximumTabCount,
              Set(session.tabs.map(\.id)).count == session.tabs.count,
              session.tabs.contains(where: { $0.id == session.selectedID }),
              session.tabs.allSatisfy({ ($0.kind != .localPDF || ($0.url == nil && !$0.mayReload))
                  && (!$0.isSleeping || ($0.kind == .web && $0.mayReload && Self.persistableURL($0.url) != nil)) }) else { throw Failure.invalidData }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM session_tabs")
            for (index, tab) in session.tabs.enumerated() {
                let row = try statement("INSERT INTO session_tabs VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
                defer { sqlite3_finalize(row) }
                try bind(tab.id.uuidString, to: 1, in: row)
                guard sqlite3_bind_int(row, 2, Int32(index)) == SQLITE_OK else { throw Failure.unavailable }
                try bind(String(tab.title.prefix(512)), to: 3, in: row)
                try bind(Self.persistableURL(tab.url)?.absoluteString, to: 4, in: row)
                try bind(tab.kind.rawValue, to: 6, in: row)
                guard sqlite3_bind_int(row, 5, tab.mayReload ? 1 : 0) == SQLITE_OK,
                      sqlite3_bind_int(row, 7, tab.isKept ? 1 : 0) == SQLITE_OK,
                      sqlite3_bind_int(row, 8, tab.isSleeping ? 1 : 0) == SQLITE_OK,
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

    // One validated snapshot of the last clean exit. Failed copies never replace it.
    func writeCleanBackup() throws {
        guard let saved = try load(), !saved.wasRunning else { throw Failure.invalidData }
        let manager = FileManager.default
        if manager.fileExists(atPath: backupURL.path) {
            guard try manager.attributesOfItem(atPath: backupURL.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.unavailable
            }
        }
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".session-backup-" + UUID().uuidString + ".sqlite3")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
        defer {
            for suffix in ["", "-journal", "-wal", "-shm"] {
                try? manager.removeItem(atPath: temporary.path + suffix)
            }
        }
        try copyDatabase(to: temporary)
        guard try Self.checkedSnapshot(at: temporary) == saved else { throw Failure.invalidData }
        if manager.fileExists(atPath: backupURL.path) {
            _ = try manager.replaceItemAt(backupURL, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: temporary, to: backupURL)
        }
    }

    private func copyDatabase(to destinationURL: URL) throws {
        guard let database else { throw Failure.unavailable }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close(destination) }
            throw Failure.unavailable
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else { throw Failure.unavailable }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw Failure.unavailable }
    }

    private static func checkedSnapshot(at url: URL) throws -> SavedSession? {
        let copy = try SessionStore(fileURL: url, readOnly: true)
        return try withExtendedLifetime(copy) {
            let check = try copy.statement("PRAGMA quick_check")
            defer { sqlite3_finalize(check) }
            guard sqlite3_step(check) == SQLITE_ROW, try copy.text(check, 0) == "ok",
                  sqlite3_step(check) == SQLITE_DONE else { throw Failure.invalidData }
            return try copy.load()
        }
    }

    private struct Location: Codable {
        let version: Int
        let fileName: String
    }

    static func currentFileURL(in directory: URL) throws -> URL {
        let manager = FileManager.default
        let pointer = directory.appendingPathComponent("current-session.json")
        guard manager.fileExists(atPath: pointer.path) else {
            if (try? manager.attributesOfItem(atPath: pointer.path)) != nil { throw Failure.invalidData }
            if manager.fileExists(atPath: directory.path) {
                let names = try manager.contentsOfDirectory(atPath: directory.path)
                guard !names.contains(where: validRecoveryName), !names.contains("current-session.json") else {
                    throw Failure.invalidData
                }
            }
            return directory.appendingPathComponent("session.sqlite3")
        }
        let attributes = try manager.attributesOfItem(atPath: pointer.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 4096 else {
            throw Failure.invalidData
        }
        let location = try JSONDecoder().decode(Location.self, from: Data(contentsOf: pointer))
        guard location.version <= 1 else { throw Failure.newerVersion }
        guard location.version == 1, validRecoveryName(location.fileName) else { throw Failure.invalidData }
        let target = directory.appendingPathComponent(location.fileName)
        if let targetAttributes = try? manager.attributesOfItem(atPath: target.path) {
            guard targetAttributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidData }
        }
        return target
    }

    private static func validRecoveryName(_ name: String) -> Bool {
        let prefix = "recovered-session-"
        let suffix = ".sqlite3"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let rawID = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: rawID)?.uuidString == rawID
    }

    static func readCleanBackup(of original: URL) throws -> SavedSession {
        guard let saved = try checkedSnapshot(at: original.appendingPathExtension("backup")),
              !saved.wasRunning else { throw Failure.invalidData }
        return saved
    }

    // Recovery forks into a new DB; unreadable originals and their sidecars stay in place.
    static func recoverCleanBackup(of original: URL) throws -> SessionStore {
        let saved = try readCleanBackup(of: original)
        let directory = original.deletingLastPathComponent()
        let name = "recovered-session-" + UUID().uuidString + ".sqlite3"
        let recovered = try SessionStore(fileURL: directory.appendingPathComponent(name))
        try recovered.save(saved)
        try recovered.writeCleanBackup()
        try recovered.save(SavedSession(tabs: saved.tabs, selectedID: saved.selectedID, wasRunning: true))
        let pointer = directory.appendingPathComponent("current-session.json")
        let manager = FileManager.default
        if manager.fileExists(atPath: pointer.path) {
            guard try manager.attributesOfItem(atPath: pointer.path)[.type] as? FileAttributeType == .typeRegular else {
                throw Failure.invalidData
            }
        }
        let temporary = directory.appendingPathComponent(".session-location-" + UUID().uuidString + ".json")
        defer { try? manager.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(Location(version: 1, fileName: name))
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw Failure.unavailable
        }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if manager.fileExists(atPath: pointer.path) {
            _ = try manager.replaceItemAt(pointer, withItemAt: temporary, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: temporary, to: pointer)
        }
        return recovered
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
        let result: Int32
        if let value {
            guard let length = Int32(exactly: value.utf8.count) else { throw Failure.invalidData }
            result = value.withCString { sqlite3_bind_text(statement, index, $0, length, transient) }
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw Failure.unavailable }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) throws -> String? {
        let type = sqlite3_column_type(statement, index)
        if type == SQLITE_NULL { return nil }
        guard type == SQLITE_TEXT, let value = sqlite3_column_text(statement, index) else { throw Failure.invalidData }
        let length = sqlite3_column_bytes(statement, index)
        guard length >= 0,
              let string = String(bytes: UnsafeBufferPointer(start: value, count: Int(length)), encoding: .utf8) else {
            throw Failure.invalidData
        }
        return string
    }
}
