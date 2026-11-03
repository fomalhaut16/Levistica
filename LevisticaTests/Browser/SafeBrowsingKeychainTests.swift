import Foundation
import Security
import Testing
@testable import Levistica

struct SafeBrowsingKeychainTests {
    // No test accesses the real keychain. These are synthetic key bytes only.
    @Test func validSyntheticKeyBytesRemainExact() throws {
        let value = "synthetic_ONLY-123456789"
        #expect(try SafeBrowsingKeychain.decode(Data(value.utf8)) == value)
    }

    @Test(arguments: [Data(), Data(repeating: 65, count: 15), Data(repeating: 65, count: 257),
                      Data("synthetic-key-123456\n".utf8), Data("synthetic key 123456".utf8),
                      Data("synthetic-key-123456é".utf8), Data(repeating: 0xff, count: 32)])
    func invalidOrInjectedBytesAreRejected(bytes: Data) {
        #expect(throws: SafeBrowsingKeychainError.invalidKey) { try SafeBrowsingKeychain.decode(bytes) }
    }

    @Test func authorizationErrorsAreSanitizedAndNeverTreatedAsMissing() throws {
        try SafeBrowsingKeychain.validate(status: errSecSuccess)
        #expect(throws: SafeBrowsingKeychainError.missing) { try SafeBrowsingKeychain.validate(status: errSecItemNotFound) }
        #expect(throws: SafeBrowsingKeychainError.authorizationRequired) { try SafeBrowsingKeychain.validate(status: errSecInteractionNotAllowed) }
        for status in [errSecUserCanceled, errSecAuthFailed] {
            #expect(throws: SafeBrowsingKeychainError.denied) { try SafeBrowsingKeychain.validate(status: status) }
        }
        #expect(throws: SafeBrowsingKeychainError.unavailable) { try SafeBrowsingKeychain.validate(status: errSecNotAvailable) }
    }
}
