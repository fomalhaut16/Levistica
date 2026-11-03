import CryptoKit
import Darwin
import Foundation

enum SafeBrowsingURLError: Error { case invalidURL, limitExceeded, invalidSuffixList }

// https://publicsuffix.org/list/ -- ICANN and private rules both matter.
struct SafeBrowsingPublicSuffixes: Sendable {
    private let exact: Set<String>
    private let wildcard: Set<String>
    private let exceptions: Set<String>

    init(text: String) throws {
        guard text.utf8.count <= 1_048_576 else { throw SafeBrowsingURLError.limitExceeded }
        var exact = Set<String>(), wildcard = Set<String>(), exceptions = Set<String>()
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            if rule.isEmpty || rule.hasPrefix("//") { continue }
            count += 1
            guard count <= 30_000 else { throw SafeBrowsingURLError.limitExceeded }
            if rule == "*" { continue }
            let isException = rule.hasPrefix("!"), isWildcard = rule.hasPrefix("*.")
            let bare = String(rule.dropFirst(isException ? 1 : (isWildcard ? 2 : 0)))
            let host = try SafeBrowsingURL.asciiDomain(bare)
            if isException { exceptions.insert(host) }
            else if isWildcard { wildcard.insert(host) }
            else { exact.insert(host) }
        }
        guard count > 0 else { throw SafeBrowsingURLError.invalidSuffixList }
        self.exact = exact; self.wildcard = wildcard; self.exceptions = exceptions
    }

    static func bundled() throws -> Self {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat") else {
            throw SafeBrowsingURLError.invalidSuffixList
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw SafeBrowsingURLError.invalidSuffixList
        }
        return try Self(text: text)
    }

    // Input is already an ASCII hostname, never an IP literal.
    func registrableDomain(_ host: String) -> String? {
        let labels = host.split(separator: ".")
        var suffixCount = 1 // The implicit '*' rule.
        for index in labels.indices {
            let suffix = labels[index...].joined(separator: ".")
            if exceptions.contains(suffix) {
                suffixCount = labels.count - index - 1
                break
            }
            if exact.contains(suffix) { suffixCount = max(suffixCount, labels.count - index) }
            if index > 0 && wildcard.contains(suffix) { suffixCount = max(suffixCount, labels.count - index + 1) }
        }
        guard labels.count > suffixCount else { return nil }
        return labels.suffix(suffixCount + 1).joined(separator: ".")
    }
}

// https://developers.google.com/safe-browsing/reference/URLs.and.Hashing
// This transforms lookup expressions only; it never rewrites a navigation URL.
enum SafeBrowsingURL {
    struct Canonical: Equatable, Sendable {
        let host: String
        let path: String
        let query: String?
        let isIPAddress: Bool
    }

    static func canonicalize(_ input: String) throws -> Canonical {
        guard input.utf8.count <= 65_536 else { throw SafeBrowsingURLError.limitExceeded }
        let filtered = Array(input.utf8.filter { ![9, 10, 13].contains($0) })
        guard let start = filtered.firstIndex(where: { $0 > 32 }),
              let finish = filtered.lastIndex(where: { $0 > 32 }) else { throw SafeBrowsingURLError.invalidURL }
        var bytes = Array(filtered[start...finish])
        if let fragment = bytes.firstIndex(of: 35) { bytes.removeSubrange(fragment...) }
        var completed = false
        for _ in 0..<128 {
            let next = unescape(bytes)
            if next == bytes { completed = true; break }
            bytes = next
        }
        guard completed else { throw SafeBrowsingURLError.limitExceeded }
        guard let colon = bytes.firstIndex(of: 58),
              let scheme = String(bytes: bytes[..<colon], encoding: .utf8)?.lowercased(),
              ["http", "https"].contains(scheme),
              bytes.count > colon + 2, bytes[colon+1] == 47, bytes[colon+2] == 47 else {
            throw SafeBrowsingURLError.invalidURL
        }
        let rest = Array(bytes.dropFirst(colon + 3))
        let end = rest.firstIndex(where: { $0 == 47 || $0 == 63 }) ?? rest.count
        guard var authority = String(bytes: rest[..<end], encoding: .utf8), !authority.isEmpty else {
            throw SafeBrowsingURLError.invalidURL
        }
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        let host: String, isIP: Bool
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { throw SafeBrowsingURLError.invalidURL }
            try validatePort(String(authority[authority.index(after: close)...]))
            host = try ipv6(String(authority[authority.index(after: authority.startIndex)..<close]))
            isIP = true
        } else {
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { throw SafeBrowsingURLError.invalidURL }
            if parts.count == 2 { try validatePort(":" + parts[1]) }
            let stripped = parts[0].split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
            if let address = ipv4(stripped) { host = address; isIP = true }
            else { host = try asciiDomain(stripped); isIP = false }
        }
        let tail = Array(rest.dropFirst(end))
        let queryIndex = tail.firstIndex(of: 63)
        let rawPath = Array(tail[..<(queryIndex ?? tail.count)])
        guard rawPath.isEmpty || rawPath.first == 47 else { throw SafeBrowsingURLError.invalidURL }
        var segments: [[UInt8]] = []
        for part in rawPath.split(separator: 47) {
            if part == [46] { continue }
            if part == [46,46] { if !segments.isEmpty { segments.removeLast() }; continue }
            segments.append(Array(part))
        }
        var path: [UInt8] = [47]
        for (index, part) in segments.enumerated() {
            if index > 0 { path.append(47) }; path += part
        }
        let last = rawPath.split(separator: 47).last
        if path.count > 1 && (rawPath.last == 47 || last == [46] || last == [46,46]) { path.append(47) }
        let query = queryIndex.map { escape(Array(tail.dropFirst($0 + 1))) }.flatMap { $0.isEmpty ? nil : $0 }
        return Canonical(host: host, path: escape(path), query: query, isIPAddress: isIP)
    }

    static func expressions(for url: URL, suffixes: SafeBrowsingPublicSuffixes) throws -> [String] {
        let canonical = try canonicalize(url.absoluteString)
        var hosts = [canonical.host]
        if !canonical.isIPAddress, let domain = suffixes.registrableDomain(canonical.host) {
            let labels = canonical.host.split(separator: ".")
            let start = labels.count - domain.split(separator: ".").count
            for index in stride(from: start, through: max(0, start - 3), by: -1) {
                let suffix = labels[index...].joined(separator: ".")
                if !hosts.contains(suffix) { hosts.append(suffix) }
            }
        }
        var paths: [String] = []
        if let query = canonical.query { paths.append(canonical.path + "?" + query) }
        paths.append(canonical.path)
        var prefix = "/"
        if !paths.contains(prefix) { paths.append(prefix) }
        let pieces = canonical.path.split(separator: "/", omittingEmptySubsequences: true)
        let directories = canonical.path.hasSuffix("/") ? pieces.count : max(0, pieces.count - 1)
        for component in pieces.prefix(min(3, directories)) {
            prefix += component + "/"
            if !paths.contains(prefix) { paths.append(prefix) }
        }
        return hosts.flatMap { host in paths.map { host + $0 } }
    }

    static func hashes(for url: URL, suffixes: SafeBrowsingPublicSuffixes) throws -> [Data] {
        try expressions(for: url, suffixes: suffixes).map { Data(SHA256.hash(data: Data($0.utf8))) }
    }

    static func asciiDomain(_ input: String) throws -> String {
        guard !input.isEmpty, input.utf8.count <= 1024,
              !input.contains(where: { $0.isWhitespace || "/:@[]?#%*\\".contains($0) }),
              let url = URL(string: "https://" + input + "/") else { throw SafeBrowsingURLError.invalidURL }
        // URL.host() may return percent-encoded Unicode on macOS. The serialized
        // authority carries the browser's ASCII IDNA representation instead.
        let serialized = url.absoluteString
        let domain = String(serialized.dropFirst(8).prefix(while: { $0 != "/" })).lowercased()
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard domain.utf8.count <= 253, domain.unicodeScalars.allSatisfy({ $0.isASCII }),
              labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }) else {
            throw SafeBrowsingURLError.invalidURL
        }
        return domain
    }

    private static func validatePort(_ suffix: String) throws {
        if suffix.isEmpty { return }
        guard suffix.first == ":", let value = UInt16(suffix.dropFirst()), value > 0 else {
            throw SafeBrowsingURLError.invalidURL
        }
    }

    private static func unescape(_ input: [UInt8]) -> [UInt8] {
        func hex(_ value: UInt8) -> UInt8? {
            switch value { case 48...57: value - 48; case 65...70: value - 55; case 97...102: value - 87; default: nil }
        }
        var output: [UInt8] = []; output.reserveCapacity(input.count)
        var index = 0
        while index < input.count {
            if input[index] == 37, index + 2 < input.count, let high = hex(input[index+1]), let low = hex(input[index+2]) {
                output.append(high * 16 + low); index += 3
            } else { output.append(input[index]); index += 1 }
        }
        return output
    }

    private static func escape(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var result: [UInt8] = []; result.reserveCapacity(bytes.count)
        for byte in bytes {
            if byte <= 32 || byte >= 127 || byte == 35 || byte == 37 {
                result += [37, digits[Int(byte >> 4)], digits[Int(byte & 15)]]
            } else { result.append(byte) }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func ipv4(_ input: String) -> String? {
        let components = input.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return nil }
        var parts: [UInt64] = []
        for component in components {
            let text = component.lowercased()
            let radix = text.hasPrefix("0x") ? 16 : (text.count > 1 && text.first == "0" ? 8 : 10)
            let digits = radix == 16 ? String(text.dropFirst(2)) : text
            guard let value = UInt64(digits, radix: radix) else { return nil }
            parts.append(value)
        }
        guard parts.dropLast().allSatisfy({ $0 <= 255 }),
              let last = parts.last, last < UInt64(1) << (8 * (5 - parts.count)) else { return nil }
        var value = last
        for (index, part) in parts.dropLast().enumerated() { value |= part << (24 - 8 * index) }
        return [24,16,8,0].map { String((value >> $0) & 255) }.joined(separator: ".")
    }

    private static func ipv6(_ input: String) throws -> String {
        var address = in6_addr()
        guard inet_pton(AF_INET6, input, &address) == 1 else { throw SafeBrowsingURLError.invalidURL }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if Array(bytes.prefix(12)) == [0,0,0,0,0,0,0,0,0,0,255,255] ||
            Array(bytes.prefix(12)) == [0,100,255,155,0,0,0,0,0,0,0,0] {
            return bytes.suffix(4).map(String.init).joined(separator: ".")
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { throw SafeBrowsingURLError.invalidURL }
        let output = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return "[" + String(decoding: output, as: UTF8.self) + "]"
    }
}
