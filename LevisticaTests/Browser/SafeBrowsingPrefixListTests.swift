import CryptoKit
import Foundation
import Testing
@testable import Levistica

struct SafeBrowsingPrefixListTests {
    private func rice(_ fields: [String: Any]) throws -> SafeBrowsingRice32 {
        try JSONDecoder().decode(SafeBrowsingRice32.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func update(_ fields: [String: Any]) throws -> SafeBrowsingPrefixUpdate {
        var body: [String: Any] = ["name": "se-4b", "version": Data([1]).base64EncodedString()]
        body.merge(fields) { _, value in value }
        return try JSONDecoder().decode(SafeBrowsingPrefixUpdate.self, from: JSONSerialization.data(withJSONObject: body))
    }

    private func checksum(_ bytes: [UInt8]) -> String { Data(SHA256.hash(data: Data(bytes))).base64EncodedString() }

    @Test func officialV5RiceExamplePreservesNetworkByteOrder() throws {
        // Google's Local Database example: b.example.com/, a.example.com/, y.example.com/.
        let encoded = try rice(["firstValue": 0x1d32c508, "riceParameter": 30, "entriesCount": 2,
                                "encodedData": Data([0x74, 0, 0xd2, 0x97, 0x1b, 0xed, 0x49, 0x74, 0]).base64EncodedString()])
        #expect(try encoded.values(maximumCount: 3) == [0x1d32c508, 0x291bc542, 0xf7a502e5])
        let list = try SafeBrowsingPrefixList.applying(update([
            "additionsFourBytes": ["firstValue": 0x1d32c508, "riceParameter": 30, "entriesCount": 2,
                                    "encodedData": Data([0x74, 0, 0xd2, 0x97, 0x1b, 0xed, 0x49, 0x74, 0]).base64EncodedString()],
            "sha256Checksum": checksum([0x1d,0x32,0xc5,0x08,0x29,0x1b,0xc5,0x42,0xf7,0xa5,0x02,0xe5])]))
        #expect(list.count == 3)
        for prefix: UInt32 in [0x1d32c508, 0x291bc542, 0xf7a502e5] { #expect(list.contains(prefix)) }
        for prefix: UInt32 in [0, 0x1d32c507, 0x1d32c509, .max] { #expect(list.contains(prefix) == false) }
    }

    @Test func singleZeroUsesProtobufDefaults() throws {
        #expect(try rice([:]).values(maximumCount: 1) == [0])
    }

    @Test(arguments: [-1, 1, 2, 31, 63])
    func invalidRiceParameterFails(parameter: Int) throws {
        let value = try rice(["riceParameter": parameter, "entriesCount": 1, "encodedData": "AgAAAA=="])
        #expect(throws: SafeBrowsingListError.invalidEncoding) { try value.values(maximumCount: 4) }
    }

    @Test func boundsAreCheckedBeforeAllocating() throws {
        let huge = try rice(["entriesCount": Int.max, "riceParameter": 30])
        #expect(throws: SafeBrowsingListError.limitExceeded) { try huge.values(maximumCount: 4_000_000) }
        let negative = try rice(["entriesCount": -1])
        #expect(throws: SafeBrowsingListError.limitExceeded) { try negative.values(maximumCount: 10) }
        let limit = try rice(["entriesCount": 4, "riceParameter": 3, "encodedData": "IiIi"])
        #expect(throws: SafeBrowsingListError.limitExceeded) { try limit.values(maximumCount: 4) }
    }

    @Test func truncatedDeltaAndUnaryOverflowFail() throws {
        let truncated = try rice(["entriesCount": 1, "riceParameter": 30, "encodedData": "Ag=="])
        #expect(throws: SafeBrowsingListError.truncated) { try truncated.values(maximumCount: 2) }
        let unary = try rice(["entriesCount": 1, "riceParameter": 30, "encodedData": "/////w=="])
        #expect(throws: SafeBrowsingListError.overflow) { try unary.values(maximumCount: 2) }
        let sum = try rice(["firstValue": UInt32.max, "entriesCount": 1, "riceParameter": 30, "encodedData": "AgAAAA=="])
        #expect(throws: SafeBrowsingListError.overflow) { try sum.values(maximumCount: 2) }
    }

    @Test func duplicateDeltaAndSurplusBytesFail() throws {
        let duplicate = try rice(["entriesCount": 1, "riceParameter": 3, "encodedData": "AA=="])
        #expect(throws: SafeBrowsingListError.notIncreasing) { try duplicate.values(maximumCount: 2) }
        let extra = try rice(["entriesCount": 0, "encodedData": "AA=="])
        #expect(throws: SafeBrowsingListError.invalidEncoding) { try extra.values(maximumCount: 2) }
        // One terminating zero plus remainder 001, then four unused high bits.
        #expect(try rice(["entriesCount": 1, "riceParameter": 3, "encodedData": "8g=="]).values(maximumCount: 2) == [0, 1])
    }

    @Test func verifiedPartialUpdateRemovesBeforeAddingAndKeepsOriginal() throws {
        let original = try SafeBrowsingPrefixList.applying(update([
            "additionsFourBytes": ["firstValue": 1, "entriesCount": 1, "riceParameter": 3, "encodedData": "BA=="],
            "sha256Checksum": checksum([0,0,0,1,0,0,0,3])]))
        let next = try SafeBrowsingPrefixList.applying(update([
            "partialUpdate": true, "compressedRemovals": [:],
            "additionsFourBytes": ["firstValue": 2], "version": "Ag==",
            "sha256Checksum": checksum([0,0,0,2,0,0,0,3])]), to: original)
        #expect(next.count == 2 && next.contains(2) && next.contains(3) && next.contains(1) == false)
        #expect(next.version == Data([2]))
        #expect(original.contains(1) && original.contains(2) == false && original.version == Data([1]))
        let bad = try update(["partialUpdate": true, "compressedRemovals": ["firstValue": 2], "sha256Checksum": checksum([])])
        #expect(throws: SafeBrowsingListError.invalidUpdate) { try SafeBrowsingPrefixList.applying(bad, to: original) }
        #expect(original.count == 2 && original.contains(1))
    }

    @Test func noChangeCanReuseChecksumButChangedDataCannot() throws {
        let original = try SafeBrowsingPrefixList.applying(update(["sha256Checksum": checksum([])]))
        let next = try SafeBrowsingPrefixList.applying(update(["partialUpdate": true, "version": "Aw=="]), to: original)
        #expect(next.count == 0 && next.version == Data([3]))
        #expect(throws: SafeBrowsingListError.invalidUpdate) {
            try SafeBrowsingPrefixList.applying(update(["partialUpdate": true, "additionsFourBytes": [:]]), to: original)
        }
    }

    @Test func corruptionNeverPublishesReplacement() throws {
        let original = try SafeBrowsingPrefixList.applying(update(["sha256Checksum": checksum([])]))
        let bad = try update(["partialUpdate": true, "additionsFourBytes": [:], "sha256Checksum": checksum([])])
        #expect(throws: SafeBrowsingListError.checksumMismatch) { try SafeBrowsingPrefixList.applying(bad, to: original) }
        #expect(original.count == 0)
        #expect(throws: SafeBrowsingListError.invalidUpdate) { try SafeBrowsingPrefixList.applying(update([:])) }
    }

    @Test func mismatchedListAndWrongHashSizeAreRejected() throws {
        #expect(throws: SafeBrowsingListError.invalidUpdate) { try update(["additionsEightBytes": [:]]) }
        #expect(throws: SafeBrowsingListError.invalidUpdate) {
            try SafeBrowsingPrefixList.applying(update(["name": "gc-32b", "sha256Checksum": checksum([])]))
        }
        #expect(throws: SafeBrowsingListError.invalidUpdate) {
            try SafeBrowsingPrefixList.applying(update(["partialUpdate": true, "sha256Checksum": checksum([])]))
        }
        let original = try SafeBrowsingPrefixList.applying(update(["sha256Checksum": checksum([])]))
        #expect(throws: SafeBrowsingListError.invalidUpdate) {
            try SafeBrowsingPrefixList.applying(update(["name": "mw-4b", "partialUpdate": true]), to: original)
        }
    }

    @Test func fullReplacementDropsPreviousAndRejectsDuplicateAdditions() throws {
        let original = try SafeBrowsingPrefixList.applying(update([
            "additionsFourBytes": ["firstValue": 1], "sha256Checksum": checksum([0,0,0,1])]))
        let replacement = try SafeBrowsingPrefixList.applying(update([
            "additionsFourBytes": ["firstValue": 2], "sha256Checksum": checksum([0,0,0,2])]), to: original)
        #expect(replacement.count == 1 && replacement.contains(2) && replacement.contains(1) == false)
        #expect(throws: SafeBrowsingListError.invalidUpdate) {
            try SafeBrowsingPrefixList.applying(update([
                "partialUpdate": true, "additionsFourBytes": ["firstValue": 1],
                "sha256Checksum": checksum([0,0,0,1])]), to: original)
        }
        #expect(throws: SafeBrowsingListError.limitExceeded) {
            try SafeBrowsingPrefixList.applying(update([
                "partialUpdate": true, "additionsFourBytes": ["firstValue": 2],
                "sha256Checksum": checksum([0,0,0,1,0,0,0,2])]), to: original, maximumEntries: 1)
        }
        #expect(original.count == 1 && original.contains(1))
    }
}
