import Foundation
import Security

enum SafeBrowsingKeychainError: Error, Equatable {
    case missing, authorizationRequired, denied, invalidKey, unavailable
}

enum SafeBrowsingKeychain {
    // This is the exact login-keychain item created by the user's security command.
    // No list-all query, plaintext fallback, key creation or access-list changes.
    static let service = "dev.fomalhaut16.Levistica.safe-browsing"
    static let account = "Levistica"

    // Call off the main actor, only after an explicit user action. Legacy login
    // keychain items may show authorization UI even when UI-fail is requested;
    // they must not be silently read during startup or a navigation callback.
    static func readAfterUserRequest() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        try validate(status: status)
        guard let data = result as? Data else { throw SafeBrowsingKeychainError.invalidKey }
        return try decode(data)
    }

    static func validate(status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecItemNotFound: throw SafeBrowsingKeychainError.missing
        case errSecInteractionNotAllowed: throw SafeBrowsingKeychainError.authorizationRequired
        case errSecUserCanceled, errSecAuthFailed: throw SafeBrowsingKeychainError.denied
        default: throw SafeBrowsingKeychainError.unavailable
        }
    }

    static func decode(_ data: Data) throws -> String {
        guard (16...256).contains(data.count),
              data.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              let key = String(data: data, encoding: .utf8) else { throw SafeBrowsingKeychainError.invalidKey }
        return key
    }
}
