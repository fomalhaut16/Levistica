import CryptoKit
import Foundation
import Testing
@testable import Levistica

struct SafeBrowsingListCacheTests {
    private func snapshot(prefixes: Data = Data([0,0,0,1,0xff,0,0xff,0]), name: String = "se-4b") throws -> SafeBrowsingSnapshot {
        let list = try SafeBrowsingPrefixList.restored(name: name, version: Data([1,2,3]), prefixBytes: prefixes,
                                                      checksum: Data(SHA256.hash(data: prefixes)))
        return try SafeBrowsingSnapshot(list: list, updatedAt: Date(timeIntervalSince1970: 1000), refreshAfter: Date(timeIntervalSince1970: 2800))
    }
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("safe-browsing-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test func snapshotRoundTripKeepsVersionTimeAndNetworkOrder() throws {
        let original = try snapshot(), bytes = try original.encoded()
        let restored = try SafeBrowsingSnapshot(encoded: bytes)
        #expect(restored.list.count == 2 && restored.list.contains(1) && restored.list.contains(0xff00ff00))
        #expect(restored.list.version == Data([1,2,3]))
        #expect(restored.updatedAt == original.updatedAt && restored.refreshAfter == original.refreshAfter)
        #expect(restored.list.encodedPrefixes() == Data([0,0,0,1,0xff,0,0xff,0]))
        #expect(restored.list.contains(0) == false)
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 900)) == false)
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 1200)))
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 90_000)) == false)
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 1200), maximumAge: .infinity) == false)
    }

    @Test func invalidDatesAndUnsortedVerifiedBytesAreRejected() throws {
        let value = try snapshot()
        for (updated, refresh) in [(-1.0,10.0),(1000.0,999.0),(.infinity,.infinity)] {
            #expect(throws: (any Error).self) {
                try SafeBrowsingSnapshot(list: value.list, updatedAt: Date(timeIntervalSince1970: updated), refreshAfter: Date(timeIntervalSince1970: refresh))
            }
        }
        for bytes in [Data([0,0,0,2,0,0,0,1]), Data([0,0,0,1,0,0,0,1]), Data([0,0,1])] {
            #expect(throws: (any Error).self) {
                try SafeBrowsingPrefixList.restored(name: "se-4b", version: Data([1]), prefixBytes: bytes, checksum: Data(SHA256.hash(data: bytes)))
            }
        }
    }

    @Test func fractionalFileTimestampAndMinimumWaitRemainExact() throws {
        let value = try snapshot()
        let updated = Date(timeIntervalSinceReferenceDate: 815_223_123.1234567)
        let refresh = updated.addingTimeInterval(1800)
        let original = try SafeBrowsingSnapshot(list: value.list, updatedAt: updated, refreshAfter: refresh)
        let restored = try SafeBrowsingSnapshot(encoded: original.encoded())
        #expect(restored.updatedAt == updated)
        #expect(restored.refreshAfter == refresh)
        #expect(restored.refreshAfter.timeIntervalSince(restored.updatedAt) == 1800)
    }

    @Test func corruptAndTruncatedSnapshotsDoNotLoad() throws {
        let valid = try snapshot().encoded()
        for count in [0,7,12,valid.count-1] {
            #expect(throws: (any Error).self) { try SafeBrowsingSnapshot(encoded: Data(valid.prefix(count))) }
        }
        var changed = valid; changed[changed.count - 33] ^= 1
        #expect(throws: SafeBrowsingCacheError.invalidSnapshot) { try SafeBrowsingSnapshot(encoded: changed) }
        // Even with a recomputed whole-file digest, Google's prefix checksum fails.
        var forgedBody = Data(changed.dropLast(32)); forgedBody.append(contentsOf: SHA256.hash(data: forgedBody))
        #expect(throws: SafeBrowsingListError.checksumMismatch) { try SafeBrowsingSnapshot(encoded: forgedBody) }
        var extra = valid; extra.append(0)
        #expect(throws: (any Error).self) { try SafeBrowsingSnapshot(encoded: extra) }
    }

    @Test func metadataCountAndSizeAreCheckedBeforePrefixAllocation() throws {
        let valid = try snapshot().encoded()
        let length = (8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32(valid[$1]) }
        let object = try JSONSerialization.jsonObject(with: valid.subdata(in: 12..<12+Int(length)))
        let original = try #require(object as? [String: Any])
        for count in [-1,3,Int.max] {
            var header = original; header["count"] = count
            let json = try JSONSerialization.data(withJSONObject: header)
            var data = Data("LSBP001\n".utf8)
            for shift in [24,16,8,0] { data.append(UInt8(truncatingIfNeeded: UInt32(json.count) >> shift)) }
            data.append(json); data.append(valid.subdata(in: 12+Int(length)..<valid.count-32))
            data.append(contentsOf: SHA256.hash(data: data))
            #expect(throws: (any Error).self) { try SafeBrowsingSnapshot(encoded: data) }
        }
    }

    @Test func ownedCachePersistsThreeIndependentListsWithPrivatePermissions() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SafeBrowsingListCache(directory: root)
        #expect(try cache.load("se-4b") == nil)
        for name in ["se-4b","mw-4b","uws-4b"] {
            try cache.save(snapshot(name: name))
            let stored = try cache.load(name)
            let loaded = try #require(stored)
            #expect(loaded.list.name == name && loaded.list.count == 2)
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name + ".bin").path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["mw-4b.bin","owner","se-4b.bin","uws-4b.bin"])
        #expect(throws: (any Error).self) { try cache.load("../../unrelated") }
    }

    @Test func unownedDirectoryAndSymlinkTargetsArePreserved() throws {
        let base = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: base) }
        let unrelated = base.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: unrelated.appendingPathComponent("keep.txt"))
        #expect(throws: SafeBrowsingCacheError.unownedDirectory) { try SafeBrowsingListCache(directory: unrelated) }
        let directoryLink = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: unrelated)
        #expect(throws: SafeBrowsingCacheError.unownedDirectory) { try SafeBrowsingListCache(directory: directoryLink) }
        let owned = base.appendingPathComponent("owned"), cache = try SafeBrowsingListCache(directory: owned)
        let target = owned.appendingPathComponent("se-4b.bin")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: unrelated.appendingPathComponent("keep.txt"))
        #expect(throws: SafeBrowsingCacheError.invalidFile) { try cache.save(snapshot()) }
        #expect(throws: SafeBrowsingCacheError.invalidFile) { try cache.load("se-4b") }
        #expect(try Data(contentsOf: unrelated.appendingPathComponent("keep.txt")) == Data("keep".utf8))
    }

    @Test func failedWriteLeavesThePreviousSnapshotUnchanged() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path); try? FileManager.default.removeItem(at: root) }
        let cache = try SafeBrowsingListCache(directory: root)
        try cache.save(snapshot())
        let file = root.appendingPathComponent("se-4b.bin"), before = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(throws: (any Error).self) { try cache.save(snapshot(prefixes: Data([0,0,0,2]))) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func wrongNamedOrBrokenCacheIsNotTrustedOrDeleted() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = try SafeBrowsingListCache(directory: root)
        let file = root.appendingPathComponent("se-4b.bin")
        let wrong = try snapshot(name: "mw-4b").encoded(); try wrong.write(to: file)
        #expect(throws: SafeBrowsingCacheError.invalidSnapshot) { try cache.load("se-4b") }
        #expect(try Data(contentsOf: file) == wrong)
        try Data("broken".utf8).write(to: file)
        #expect(throws: (any Error).self) { try cache.load("se-4b") }
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
    }

    @Test func fullUpdateMarkerPreservesOriginalAgeAndRequestDeadline() throws {
        let value = try snapshot()
        let pending = try SafeBrowsingSnapshot(list: value.list, updatedAt: value.updatedAt,
            refreshAfter: Date(timeIntervalSince1970: 4000), requiresFullUpdate: true)
        let restored = try SafeBrowsingSnapshot(encoded: pending.encoded())
        #expect(restored.requiresFullUpdate)
        #expect(restored.updatedAt == value.updatedAt)
        #expect(restored.refreshAfter == Date(timeIntervalSince1970: 4000))
        #expect(restored.list.prefixChecksum == value.list.prefixChecksum)
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 1200)) == false)
    }

    @Test func oldSnapshotsWithoutTheRecoveryFieldStillLoad() throws {
        let current = try snapshot().encoded()
        let length = (8..<12).reduce(UInt32(0)) { ($0 << 8) | UInt32(current[$1]) }
        let object = try JSONSerialization.jsonObject(with: current.subdata(in: 12..<12+Int(length)))
        var header = try #require(object as? [String: Any])
        header.removeValue(forKey: "requiresFullUpdate")
        let json = try JSONSerialization.data(withJSONObject: header)
        var old = Data("LSBP001\n".utf8)
        for shift in [24,16,8,0] { old.append(UInt8(truncatingIfNeeded: UInt32(json.count) >> shift)) }
        old.append(json); old.append(current.subdata(in: 12+Int(length)..<current.count-32))
        old.append(contentsOf: SHA256.hash(data: old))
        let restored = try SafeBrowsingSnapshot(encoded: old)
        #expect(restored.requiresFullUpdate == false)
        #expect(restored.list.count == 2)
        #expect(restored.isRecent(at: Date(timeIntervalSince1970: 1200)))
    }

}
