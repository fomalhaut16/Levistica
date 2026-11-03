import Foundation

// Only the response messages used by this client, not a general protobuf runtime.
// https://github.com/googleapis/googleapis/blob/master/google/security/safebrowsing/v5/safebrowsing.proto
enum SafeBrowsingWireError: Error, Equatable { case malformed, limitExceeded, duplicateField, unsupportedHashLength }

private struct SafeBrowsingWireReader {
    enum Value { case integer(UInt64), bytes(Data), fixed }
    struct Field { let number: Int; let value: Value }
    let data: Data
    private var offset = 0
    private var fieldsRead = 0
    var atEnd: Bool { offset == data.count }

    init(_ data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 else { throw SafeBrowsingWireError.limitExceeded }
        self.data = Data(data) // Normalize indices, including a caller's Data slice.
    }

    mutating func integer() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < data.count else { throw SafeBrowsingWireError.malformed }
            let byte = data[offset]; offset += 1
            guard index != 9 || byte <= 1 else { throw SafeBrowsingWireError.malformed }
            value |= UInt64(byte & 127) << (index * 7)
            if byte < 128 { return value }
        }
        throw SafeBrowsingWireError.malformed
    }

    mutating func next() throws -> Field? {
        if atEnd { return nil }
        fieldsRead += 1
        guard fieldsRead <= 4096 else { throw SafeBrowsingWireError.limitExceeded }
        let tag = try integer(), number = tag >> 3
        guard number > 0, number <= 536_870_911 else { throw SafeBrowsingWireError.malformed }
        let value: Value
        switch tag & 7 {
        case 0: value = .integer(try integer())
        case 2:
            let length = try integer()
            guard length <= UInt64(data.count - offset) else { throw SafeBrowsingWireError.malformed }
            value = .bytes(data.subdata(in: offset..<offset + Int(length))); offset += Int(length)
        case 1, 5:
            let length = tag & 7 == 1 ? 8 : 4
            guard length <= data.count - offset else { throw SafeBrowsingWireError.malformed }
            offset += length; value = .fixed
        default: throw SafeBrowsingWireError.malformed // Deprecated groups are not used.
        }
        return Field(number: Int(number), value: value)
    }

    static func bytes(_ value: Value) throws -> Data {
        guard case .bytes(let data) = value else { throw SafeBrowsingWireError.malformed }; return data
    }
    static func unsigned(_ value: Value) throws -> UInt64 {
        guard case .integer(let number) = value else { throw SafeBrowsingWireError.malformed }; return number
    }
    static func unique(_ number: Int, in seen: inout Set<Int>) throws {
        guard seen.insert(number).inserted else { throw SafeBrowsingWireError.duplicateField }
    }

    static func duration(_ data: Data) throws -> TimeInterval {
        var reader = try Self(data), seconds: UInt64 = 0, nanos: UInt64 = 0, seen = Set<Int>()
        while let field = try reader.next() {
            if field.number == 1 || field.number == 2 {
                try unique(field.number, in: &seen)
                let value = try unsigned(field.value)
                if field.number == 1 { seconds = value } else { nanos = value }
            }
        }
        // protobuf.Duration bounds; negative durations have a large unsigned value.
        guard seconds <= 315_576_000_000, nanos < 1_000_000_000 else { throw SafeBrowsingWireError.malformed }
        return Double(seconds) + Double(nanos) / 1_000_000_000
    }

    static func rice(_ data: Data) throws -> SafeBrowsingRice32 {
        var reader = try Self(data), first: UInt64 = 0, parameter: UInt64 = 0, count: UInt64 = 0
        var encoded = Data(), seen = Set<Int>()
        while let field = try reader.next() {
            guard (1...4).contains(field.number) else { continue }
            try unique(field.number, in: &seen)
            if field.number == 4 { encoded = try bytes(field.value) }
            else {
                let value = try unsigned(field.value)
                switch field.number { case 1: first = value; case 2: parameter = value; default: count = value }
            }
        }
        guard first <= UInt32.max, parameter <= 30, count < SafeBrowsingPrefixList.maximumEntries else {
            throw SafeBrowsingWireError.limitExceeded
        }
        return SafeBrowsingRice32(firstValue: UInt32(first), riceParameter: Int(parameter), entriesCount: Int(count), encodedData: encoded)
    }
}

struct SafeBrowsingListResponse: Sendable {
    let update: SafeBrowsingPrefixUpdate
    let minimumWait: TimeInterval

    init(protobuf data: Data) throws {
        var reader = try SafeBrowsingWireReader(data), name: String?, version: Data?
        var partial = false, removals: SafeBrowsingRice32?, additions: SafeBrowsingRice32?, checksum: Data?
        var wait: TimeInterval = 0, seen = Set<Int>()
        while let field = try reader.next() {
            if (9...11).contains(field.number) { throw SafeBrowsingWireError.unsupportedHashLength }
            guard (1...7).contains(field.number) else { continue }
            try SafeBrowsingWireReader.unique(field.number, in: &seen)
            switch field.number {
            case 1: name = String(data: try SafeBrowsingWireReader.bytes(field.value), encoding: .utf8)
            case 2: version = try SafeBrowsingWireReader.bytes(field.value)
            case 3:
                let value = try SafeBrowsingWireReader.unsigned(field.value)
                guard value <= 1 else { throw SafeBrowsingWireError.malformed }; partial = value == 1
            case 4: additions = try SafeBrowsingWireReader.rice(SafeBrowsingWireReader.bytes(field.value))
            case 5: removals = try SafeBrowsingWireReader.rice(SafeBrowsingWireReader.bytes(field.value))
            case 6: wait = try SafeBrowsingWireReader.duration(SafeBrowsingWireReader.bytes(field.value))
            default: checksum = try SafeBrowsingWireReader.bytes(field.value)
            }
        }
        guard let name, SafeBrowsingPrefixList.names.contains(name), let version,
              !version.isEmpty, version.count <= 1024 else { throw SafeBrowsingWireError.malformed }
        update = SafeBrowsingPrefixUpdate(name: name, version: version, partialUpdate: partial,
                                         compressedRemovals: removals, additionsFourBytes: additions, sha256Checksum: checksum)
        minimumWait = wait
    }
}

enum SafeBrowsingThreat: UInt64, Sendable { case malware = 1, socialEngineering = 2, unwantedSoftware = 3 }

struct SafeBrowsingHashResponse: Sendable {
    struct Match: Sendable { let hash: Data; let threats: Set<SafeBrowsingThreat> }
    let matches: [Match]
    let cacheDuration: TimeInterval

    init(protobuf data: Data) throws {
        guard data.count <= 1_048_576 else { throw SafeBrowsingWireError.limitExceeded }
        var reader = try SafeBrowsingWireReader(data), matches: [Match] = [], duration: TimeInterval = 0
        var durationSeen = false
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard matches.count < 2048 else { throw SafeBrowsingWireError.limitExceeded }
                matches.append(try Self.match(SafeBrowsingWireReader.bytes(field.value)))
            case 2:
                guard !durationSeen else { throw SafeBrowsingWireError.duplicateField }; durationSeen = true
                duration = try SafeBrowsingWireReader.duration(SafeBrowsingWireReader.bytes(field.value))
            default: continue
            }
        }
        self.matches = matches; cacheDuration = duration
    }

    private static func match(_ data: Data) throws -> Match {
        var reader = try SafeBrowsingWireReader(data), hash: Data?, threats = Set<SafeBrowsingThreat>(), details = 0
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard hash == nil else { throw SafeBrowsingWireError.duplicateField }
                hash = try SafeBrowsingWireReader.bytes(field.value)
            case 2:
                details += 1
                guard details <= 32 else { throw SafeBrowsingWireError.limitExceeded }
                if let threat = try Self.detail(SafeBrowsingWireReader.bytes(field.value)) { threats.insert(threat) }
            default: continue
            }
        }
        guard let hash, hash.count == 32 else { throw SafeBrowsingWireError.malformed }
        return Match(hash: hash, threats: threats)
    }

    private static func detail(_ data: Data) throws -> SafeBrowsingThreat? {
        var reader = try SafeBrowsingWireReader(data), type: UInt64?, attributes: [UInt64] = []
        while let field = try reader.next() {
            switch field.number {
            case 1:
                guard type == nil else { throw SafeBrowsingWireError.duplicateField }
                type = try SafeBrowsingWireReader.unsigned(field.value)
            case 2:
                switch field.value {
                case .integer(let value): attributes.append(value)
                case .bytes(let bytes):
                    var packed = try SafeBrowsingWireReader(bytes)
                    while !packed.atEnd {
                        guard attributes.count < 32 else { throw SafeBrowsingWireError.limitExceeded }
                        attributes.append(try packed.integer())
                    }
                default: throw SafeBrowsingWireError.malformed
                }
                guard attributes.count <= 32 else { throw SafeBrowsingWireError.limitExceeded }
            default: continue
            }
        }
        // Unknown types/attributes discard the entire detail. CANARY and
        // FRAME_ONLY must not enforce a top-level desktop navigation either.
        guard attributes.isEmpty, let type else { return nil }
        return SafeBrowsingThreat(rawValue: type)
    }
}
