import CryptoKit
import Foundation
import Testing
@testable import Levistica

struct SafeBrowsingWireTests {
    // Hand-encoded wire fixtures. Each length below is deliberately one byte.
    private func field(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] { [tag, UInt8(bytes.count)] + bytes }
    private func list() -> [UInt8] {
        let sum = Array(SHA256.hash(data: Data([0,0,0,1])))
        return field(0x0a, Array("se-4b".utf8)) + [0x12,1,1, 0x22,2,0x08,1] + field(0x3a, sum)
    }
    private func detail(_ type: UInt8, attributes: [UInt8] = []) -> [UInt8] {
        [0x08,type] + (attributes.isEmpty ? [] : field(0x12, attributes))
    }
    private func match(_ details: [[UInt8]], hashLength: Int = 32) -> [UInt8] {
        field(0x0a, Array(repeating: 0x42, count: hashLength)) + details.flatMap { field(0x12, $0) }
    }

    @Test func listResponseFeedsTheExistingChecksumValidator() throws {
        let body = Data(list() + [0x32,3,0x08,0x88,0x0e]) // duration 1800 seconds
        let response = try SafeBrowsingListResponse(protobuf: body)
        let value = try SafeBrowsingPrefixList.applying(response.update)
        #expect(value.name == "se-4b" && value.count == 1 && value.contains(1))
        #expect(response.minimumWait == 1800)
        var slice = Data([0xff]); slice.append(body)
        #expect(try SafeBrowsingListResponse(protobuf: slice.dropFirst()).minimumWait == 1800)
    }

    @Test func unknownFieldsAreSkippedWithoutChangingKnownValues() throws {
        let unknown: [UInt8] = [0x78,7, 0x81,1,1,2,3,4,5,6,7,8, 0x8d,1,1,2,3,4, 0x92,1,2,0,0]
        let response = try SafeBrowsingListResponse(protobuf: Data(list() + unknown))
        #expect(try SafeBrowsingPrefixList.applying(response.update).contains(1))
        #expect(response.minimumWait == 0)
    }

    @Test(arguments: [
        [UInt8(0)], [0x0a,9,1], [0x0b], [0x0d,1],
        [0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x02],
        [0x0a,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x01]
    ])
    func malformedWireRejectsWithoutTrapping(body: [UInt8]) {
        #expect(throws: (any Error).self) { try SafeBrowsingListResponse(protobuf: Data(body)) }
    }

    @Test func duplicateAndIncorrectWireTypesAreRejected() {
        #expect(throws: SafeBrowsingWireError.duplicateField) {
            try SafeBrowsingListResponse(protobuf: Data(list() + field(0x0a, Array("se-4b".utf8))))
        }
        #expect(throws: (any Error).self) { try SafeBrowsingListResponse(protobuf: Data([0x08,1] + list())) }
        #expect(throws: (any Error).self) { try SafeBrowsingListResponse(protobuf: Data(list() + [0x18,2])) }
        #expect(throws: SafeBrowsingWireError.unsupportedHashLength) {
            try SafeBrowsingListResponse(protobuf: Data(list() + [0x4a,0]))
        }
    }

    @Test func unsignedAndDurationBoundsFailClosed() {
        // A uint32 first value cannot contain 2^32.
        let rice: [UInt8] = [0x08,0x80,0x80,0x80,0x80,0x10]
        let prefix = field(0x0a, Array("se-4b".utf8)) + [0x12,1,1]
        #expect(throws: SafeBrowsingWireError.limitExceeded) { try SafeBrowsingListResponse(protobuf: Data(prefix + field(0x22, rice))) }
        let negative: [UInt8] = [0x08] + Array(repeating: 0xff, count: 9) + [1]
        #expect(throws: (any Error).self) { try SafeBrowsingListResponse(protobuf: Data(list() + field(0x32, negative))) }
        let nanos: [UInt8] = [0x10,0x80,0x94,0xeb,0xdc,0x03]
        #expect(throws: (any Error).self) { try SafeBrowsingHashResponse(protobuf: Data(field(0x12, nanos))) }
        #expect(throws: SafeBrowsingWireError.duplicateField) {
            try SafeBrowsingHashResponse(protobuf: Data([0x12,0,0x12,0]))
        }
    }

    @Test func hashMatchesKeepKnownDesktopThreatsAndCacheTime() throws {
        let item = match([detail(1), detail(2), detail(3)])
        let response = try SafeBrowsingHashResponse(protobuf: Data(field(0x0a, item) + [0x12,2,0x08,60]))
        #expect(response.cacheDuration == 60)
        #expect(response.matches.count == 1)
        #expect(response.matches[0].hash == Data(repeating: 0x42, count: 32))
        #expect(response.matches[0].threats == [.malware, .socialEngineering, .unwantedSoftware])
        #expect(try SafeBrowsingHashResponse(protobuf: Data()).matches.isEmpty)
    }

    @Test(arguments: [
        [UInt8(0x08),0], [0x08,99], [0x08,4],
        [0x08,1,0x12,1,0], [0x08,1,0x12,1,1], [0x08,1,0x12,1,2], [0x08,1,0x12,1,99],
        [0x08,1,0x10,1], [0x08,2,0x10,2]
    ])
    func unknownCanaryFrameOnlyAndAndroidDetailsDoNotBlockTheTopPage(value: [UInt8]) throws {
        let response = try SafeBrowsingHashResponse(protobuf: Data(field(0x0a, match([value]))))
        #expect(response.matches[0].threats.isEmpty)
    }

    @Test func ignoredDetailDoesNotHideAnotherValidDetail() throws {
        let response = try SafeBrowsingHashResponse(protobuf: Data(field(0x0a, match([detail(1, attributes: [99]), detail(2)]))))
        #expect(response.matches[0].threats == [.socialEngineering])
        #expect(throws: (any Error).self) {
            try SafeBrowsingHashResponse(protobuf: Data(field(0x0a, match([detail(1)], hashLength: 31))))
        }
    }

    @Test func fieldAndBodyLimitsAreEnforced() {
        let many = Data(Array(repeating: [UInt8(0x78),0], count: 4097).flatMap { $0 })
        #expect(throws: SafeBrowsingWireError.limitExceeded) { try SafeBrowsingListResponse(protobuf: many) }
        let huge = Data(repeating: 0, count: 16 * 1024 * 1024 + 1)
        #expect(throws: SafeBrowsingWireError.limitExceeded) { try SafeBrowsingListResponse(protobuf: huge) }
        #expect(throws: SafeBrowsingWireError.limitExceeded) { try SafeBrowsingHashResponse(protobuf: huge) }
    }
}
