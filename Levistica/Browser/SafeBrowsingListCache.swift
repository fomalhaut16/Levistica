import CryptoKit
import Darwin
import Foundation

enum SafeBrowsingCacheError: Error, Equatable { case invalidSnapshot, unownedDirectory, invalidFile }

struct SafeBrowsingSnapshot: Sendable {
    let list: SafeBrowsingPrefixList
    let updatedAt: Date
    let refreshAfter: Date
    private static let magic = Data("LSBP001\n".utf8)
    static let maximumBytes = SafeBrowsingPrefixList.maximumEntries * 4 + 16_384 + 64

    private struct Header: Codable {
        let name: String
        let version: Data
        let count: Int
        let checksum: Data
        let updatedAt: Date
        let refreshAfter: Date
    }

    // Freshness is separate from the server's earliest next-request time.
    func isRecent(at now: Date, maximumAge: TimeInterval = 86_400) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return maximumAge.isFinite && maximumAge >= 0 && age >= 0 && age <= maximumAge
    }

    func encoded() throws -> Data {
        try Self.checkDates(updatedAt, refreshAfter)
        let header = Header(name: list.name, version: list.version, count: list.count,
                            checksum: list.prefixChecksum, updatedAt: updatedAt, refreshAfter: refreshAfter)
        // Date's own reference-date encoding avoids a lossy epoch conversion.
        let encoder = JSONEncoder()
        let metadata = try encoder.encode(header)
        guard metadata.count <= 16_384 else { throw SafeBrowsingCacheError.invalidSnapshot }
        var data = Self.magic
        let length = UInt32(metadata.count)
        for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: length >> shift)) }
        data.append(metadata); data.append(list.encodedPrefixes())
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    init(list: SafeBrowsingPrefixList, updatedAt: Date, refreshAfter: Date) throws {
        try Self.checkDates(updatedAt, refreshAfter)
        self.list = list; self.updatedAt = updatedAt; self.refreshAfter = refreshAfter
    }

    init(encoded input: Data) throws {
        guard input.count >= Self.magic.count + 4 + 32, input.count <= Self.maximumBytes else {
            throw SafeBrowsingCacheError.invalidSnapshot
        }
        let data = Data(input)
        guard data.prefix(Self.magic.count) == Self.magic else { throw SafeBrowsingCacheError.invalidSnapshot }
        let body = data.dropLast(32)
        guard Data(SHA256.hash(data: body)) == Data(data.suffix(32)) else { throw SafeBrowsingCacheError.invalidSnapshot }
        let sizeOffset = Self.magic.count
        let size = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[sizeOffset + $1]) }
        let metadataStart = sizeOffset + 4
        guard size <= 16_384, Int(size) <= body.count - metadataStart else { throw SafeBrowsingCacheError.invalidSnapshot }
        let prefixesStart = metadataStart + Int(size)
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data.subdata(in: metadataStart..<prefixesStart))
        guard header.count >= 0, header.count <= SafeBrowsingPrefixList.maximumEntries,
              body.count - prefixesStart == header.count * 4 else { throw SafeBrowsingCacheError.invalidSnapshot }
        try Self.checkDates(header.updatedAt, header.refreshAfter)
        list = try SafeBrowsingPrefixList.restored(name: header.name, version: header.version,
                                                 prefixBytes: data.subdata(in: prefixesStart..<body.count), checksum: header.checksum)
        updatedAt = header.updatedAt; refreshAfter = header.refreshAfter
    }

    private static func checkDates(_ updated: Date, _ refresh: Date) throws {
        guard updated.timeIntervalSince1970.isFinite, refresh.timeIntervalSince1970.isFinite,
              updated.timeIntervalSince1970 >= 0, refresh >= updated,
              refresh.timeIntervalSince(updated) <= 315_576_000_000 else { throw SafeBrowsingCacheError.invalidSnapshot }
    }
}

struct SafeBrowsingListCache: Sendable {
    private let directory: URL
    private static let marker = Data("Levistica.SafeBrowsing.v1\n".utf8)

    init(directory: URL) throws {
        guard directory.isFileURL else { throw SafeBrowsingCacheError.unownedDirectory }
        let root = URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().path else { throw SafeBrowsingCacheError.unownedDirectory }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        self.directory = root
        try checkDirectory()
        let marker = root.appendingPathComponent("owner")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw SafeBrowsingCacheError.unownedDirectory }
            try Self.marker.write(to: marker, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        try checkOwner()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    func load(_ name: String) throws -> SafeBrowsingSnapshot? {
        try checkOwner()
        let file = try file(name)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return nil }
        try checkFile(attributes, maximumBytes: SafeBrowsingSnapshot.maximumBytes)
        let snapshot = try SafeBrowsingSnapshot(encoded: Data(contentsOf: file, options: .mappedIfSafe))
        guard snapshot.list.name == name else { throw SafeBrowsingCacheError.invalidSnapshot }
        return snapshot
    }

    func save(_ snapshot: SafeBrowsingSnapshot) throws {
        try checkOwner()
        let file = try file(snapshot.list.name)
        try checkExistingTarget(file)
        let bytes = try snapshot.encoded()
        let staging = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try bytes.write(to: staging, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try checkOwner()
        try checkExistingTarget(file)
        // All fallible validation and permission work precedes the atomic commit.
        guard rename(staging.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func checkExistingTarget(_ file: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        try checkFile(attributes, maximumBytes: SafeBrowsingSnapshot.maximumBytes)
    }

    private func file(_ name: String) throws -> URL {
        guard SafeBrowsingPrefixList.names.contains(name) else { throw SafeBrowsingCacheError.invalidFile }
        return directory.appendingPathComponent(name + ".bin")
    }

    private func checkDirectory() throws {
        guard directory.path == directory.resolvingSymlinksInPath().path else { throw SafeBrowsingCacheError.unownedDirectory }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw SafeBrowsingCacheError.unownedDirectory }
    }

    private func checkOwner() throws {
        try checkDirectory()
        let file = directory.appendingPathComponent("owner")
        try checkFile(FileManager.default.attributesOfItem(atPath: file.path), maximumBytes: 128)
        guard try Data(contentsOf: file) == Self.marker else { throw SafeBrowsingCacheError.unownedDirectory }
    }

    private func checkFile(_ attributes: [FileAttributeKey: Any], maximumBytes: Int) throws {
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0, size.int64Value <= Int64(maximumBytes) else {
            throw SafeBrowsingCacheError.invalidFile
        }
    }
}
