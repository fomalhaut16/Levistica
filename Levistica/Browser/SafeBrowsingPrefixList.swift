import CryptoKit
import Foundation

// https://developers.google.com/safe-browsing/reference/rest/v5/hashList
// https://developers.google.com/safe-browsing/reference/Local.Database
// Decode only the four-byte threat lists; never reinterpret another hash size.
enum SafeBrowsingListError: Error, Equatable {
    case invalidEncoding, limitExceeded, truncated, overflow, notIncreasing
    case invalidUpdate, checksumMismatch
}

struct SafeBrowsingRice32: Decodable, Sendable {
    let firstValue: UInt32
    let riceParameter: Int
    let entriesCount: Int
    let encodedData: Data

    private enum CodingKeys: String, CodingKey {
        case firstValue, riceParameter, entriesCount, encodedData
    }

    init(firstValue: UInt32, riceParameter: Int, entriesCount: Int, encodedData: Data) {
        self.firstValue = firstValue; self.riceParameter = riceParameter
        self.entriesCount = entriesCount; self.encodedData = encodedData
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstValue = try c.decodeIfPresent(UInt32.self, forKey: .firstValue) ?? 0
        riceParameter = try c.decodeIfPresent(Int.self, forKey: .riceParameter) ?? 0
        entriesCount = try c.decodeIfPresent(Int.self, forKey: .entriesCount) ?? 0
        encodedData = try c.decodeIfPresent(Data.self, forKey: .encodedData) ?? Data()
    }

    func values(maximumCount: Int) throws -> [UInt32] {
        guard maximumCount > 0, entriesCount >= 0, entriesCount < maximumCount,
              encodedData.count <= 16 * 1024 * 1024 else {
            throw SafeBrowsingListError.limitExceeded
        }
        if entriesCount == 0 {
            guard encodedData.isEmpty else { throw SafeBrowsingListError.invalidEncoding }
            return [firstValue]
        }
        guard (3...30).contains(riceParameter) else { throw SafeBrowsingListError.invalidEncoding }
        // A delta needs at least a terminating unary bit plus k remainder bits.
        guard entriesCount <= encodedData.count * 8 / (riceParameter + 1) else {
            throw SafeBrowsingListError.truncated
        }
        return try encodedData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var position = 0
            func bit() throws -> UInt64 {
                guard position < bytes.count * 8 else { throw SafeBrowsingListError.truncated }
                defer { position += 1 }
                return UInt64((bytes[position / 8] >> (position % 8)) & 1)
            }
            var result = [UInt32]()
            result.reserveCapacity(entriesCount + 1)
            result.append(firstValue)
            var last = firstValue
            for _ in 0..<entriesCount {
                var quotient: UInt64 = 0
                while try bit() == 1 {
                    quotient += 1
                    guard quotient <= UInt64(UInt32.max) >> riceParameter else {
                        throw SafeBrowsingListError.overflow
                    }
                }
                var remainder: UInt64 = 0
                for shift in 0..<riceParameter { remainder |= try bit() << shift }
                let delta = (quotient << riceParameter) | remainder
                guard delta > 0 else { throw SafeBrowsingListError.notIncreasing }
                let next = UInt64(last) + delta
                guard next <= UInt32.max else { throw SafeBrowsingListError.overflow }
                last = UInt32(next)
                result.append(last)
            }
            // The final byte may have unused bits; they are not another delta.
            guard bytes.count * 8 - position < 8 else { throw SafeBrowsingListError.invalidEncoding }
            return result
        }
    }
}

struct SafeBrowsingPrefixUpdate: Decodable, Sendable {
    let name: String
    let version: Data
    let partialUpdate: Bool
    let compressedRemovals: SafeBrowsingRice32?
    let additionsFourBytes: SafeBrowsingRice32?
    let sha256Checksum: Data?

    private enum CodingKeys: String, CodingKey {
        case name, version, partialUpdate, compressedRemovals, additionsFourBytes, sha256Checksum
        case additionsEightBytes, additionsSixteenBytes, additionsThirtyTwoBytes
    }

    init(name: String, version: Data, partialUpdate: Bool, compressedRemovals: SafeBrowsingRice32?,
         additionsFourBytes: SafeBrowsingRice32?, sha256Checksum: Data?) {
        self.name = name; self.version = version; self.partialUpdate = partialUpdate
        self.compressedRemovals = compressedRemovals; self.additionsFourBytes = additionsFourBytes
        self.sha256Checksum = sha256Checksum
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard !c.contains(.additionsEightBytes), !c.contains(.additionsSixteenBytes),
              !c.contains(.additionsThirtyTwoBytes) else { throw SafeBrowsingListError.invalidUpdate }
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(Data.self, forKey: .version)
        partialUpdate = try c.decodeIfPresent(Bool.self, forKey: .partialUpdate) ?? false
        compressedRemovals = try c.decodeIfPresent(SafeBrowsingRice32.self, forKey: .compressedRemovals)
        additionsFourBytes = try c.decodeIfPresent(SafeBrowsingRice32.self, forKey: .additionsFourBytes)
        sha256Checksum = try c.decodeIfPresent(Data.self, forKey: .sha256Checksum)
    }
}

struct SafeBrowsingPrefixList: Sendable {
    static let maximumEntries = 4_000_000
    static let names: Set<String> = ["se-4b", "mw-4b", "uws-4b"]
    let name: String
    let version: Data
    private let prefixes: [UInt32]
    private let checksum: Data
    var count: Int { prefixes.count }
    var prefixChecksum: Data { checksum }

    func encodedPrefixes() -> Data {
        var data = Data(); data.reserveCapacity(prefixes.count * 4)
        for prefix in prefixes {
            for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: prefix >> shift)) }
        }
        return data
    }

    static func restored(name: String, version: Data, prefixBytes: Data, checksum: Data) throws -> Self {
        guard names.contains(name), !version.isEmpty, version.count <= 1024,
              prefixBytes.count.isMultiple(of: 4), prefixBytes.count / 4 <= maximumEntries,
              checksum.count == 32 else { throw SafeBrowsingListError.invalidUpdate }
        guard Data(SHA256.hash(data: prefixBytes)) == checksum else { throw SafeBrowsingListError.checksumMismatch }
        var prefixes: [UInt32] = []; prefixes.reserveCapacity(prefixBytes.count / 4)
        for start in stride(from: prefixBytes.startIndex, to: prefixBytes.endIndex, by: 4) {
            let value = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(prefixBytes[start + $1]) }
            if let previous = prefixes.last, previous >= value { throw SafeBrowsingListError.notIncreasing }
            prefixes.append(value)
        }
        return Self(name: name, version: version, prefixes: prefixes, checksum: checksum)
    }

    func contains(_ prefix: UInt32) -> Bool {
        var low = 0, high = prefixes.count
        while low < high {
            let middle = low + (high - low) / 2
            if prefixes[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        return low < prefixes.count && prefixes[low] == prefix
    }

    // Build a replacement value and verify it before the caller publishes it.
    // A failed update cannot mutate the previously validated list.
    static func applying(_ update: SafeBrowsingPrefixUpdate, to previous: Self? = nil,
                         maximumEntries: Int = Self.maximumEntries) throws -> Self {
        guard names.contains(update.name), !update.version.isEmpty, update.version.count <= 1024,
              maximumEntries > 0, maximumEntries <= Self.maximumEntries else {
            throw SafeBrowsingListError.invalidUpdate
        }
        let old: [UInt32]
        if update.partialUpdate {
            guard let previous, previous.name == update.name else { throw SafeBrowsingListError.invalidUpdate }
            old = previous.prefixes
        } else {
            guard update.compressedRemovals == nil else { throw SafeBrowsingListError.invalidUpdate }
            old = []
        }
        let unchanged = update.partialUpdate && update.compressedRemovals == nil && update.additionsFourBytes == nil
        let expected = update.sha256Checksum ?? (unchanged ? previous?.checksum : nil)
        guard let expected, expected.count == 32 else { throw SafeBrowsingListError.invalidUpdate }
        let removals = try update.compressedRemovals?.values(maximumCount: maximumEntries) ?? []
        let additions = try update.additionsFourBytes?.values(maximumCount: maximumEntries) ?? []
        guard removals.allSatisfy({ UInt64($0) < UInt64(old.count) }) else { throw SafeBrowsingListError.invalidUpdate }
        let resultingCount = old.count - removals.count + additions.count
        guard resultingCount >= 0, resultingCount <= maximumEntries else { throw SafeBrowsingListError.limitExceeded }
        var merged: [UInt32] = []
        merged.reserveCapacity(resultingCount)
        var oldIndex = 0, removeIndex = 0, addIndex = 0
        while oldIndex < old.count || addIndex < additions.count {
            if oldIndex < old.count, removeIndex < removals.count,
               oldIndex == Int(removals[removeIndex]) {
                oldIndex += 1; removeIndex += 1; continue
            }
            if addIndex < additions.count && (oldIndex == old.count || additions[addIndex] < old[oldIndex]) {
                merged.append(additions[addIndex]); addIndex += 1
            } else {
                if addIndex < additions.count, oldIndex < old.count, additions[addIndex] == old[oldIndex] {
                    throw SafeBrowsingListError.invalidUpdate
                }
                merged.append(old[oldIndex]); oldIndex += 1
            }
        }
        var hasher = SHA256()
        // Hash network-order prefixes in bounded chunks, not one giant Data copy.
        var chunk = Data(); chunk.reserveCapacity(16_384)
        for value in merged {
            chunk.append(UInt8(truncatingIfNeeded: value >> 24))
            chunk.append(UInt8(truncatingIfNeeded: value >> 16))
            chunk.append(UInt8(truncatingIfNeeded: value >> 8))
            chunk.append(UInt8(truncatingIfNeeded: value))
            if chunk.count == 16_384 { hasher.update(data: chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { hasher.update(data: chunk) }
        guard Data(hasher.finalize()) == expected else { throw SafeBrowsingListError.checksumMismatch }
        return Self(name: update.name, version: update.version, prefixes: merged, checksum: expected)
    }
}
