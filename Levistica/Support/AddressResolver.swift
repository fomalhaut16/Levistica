import Foundation

enum AddressError: Error, Equatable, LocalizedError {
    case empty
    case invalid
    case unsupportedScheme
    case restrictedPort

    var errorDescription: String? {
        switch self {
        case .empty: "URLまたは検索語を入力してください。"
        case .invalid: "URLを確認してください。"
        case .unsupportedScheme: "URL欄ではHTTPとHTTPSのページを開けます。"
        case .restrictedPort: "この接続先ポートには、ブラウザから接続できません。"
        }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Hashable, Sendable {
    case duckDuckGo, google

    var displayName: String { self == .google ? "Google" : "DuckDuckGo" }

    func searchURL(for query: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = self == .google ? "www.google.com" : "duckduckgo.com"
        components.path = self == .google ? "/search" : "/"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search servers decode query strings as form data. A literal '+' must
        // be escaped even though URLComponents permits it in a URL query.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw AddressError.invalid }
        return url
    }
}

enum AddressResolver {
    static func resolve(_ input: String, searchEngine: SearchEngine = .duckDuckGo) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AddressError.empty }
        guard !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !text.hasPrefix("/"), !text.hasPrefix("~"), !text.contains("\\") else {
            throw AddressError.invalid
        }

        // A host:port is an address, not an application scheme.
        let hasHostPort = text.range(of: #"^(localhost|[^\s/:]+\.[^\s/:]+):[0-9]+(?:/|$)"#,
                                    options: .regularExpression) != nil
        let hasScheme = text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                                  options: .regularExpression) != nil
        if hasScheme && !hasHostPort {
            let scheme = String(text.prefix { $0 != ":" }).lowercased()
            guard ["http", "https"].contains(scheme) else { throw AddressError.unsupportedScheme }
            return try webURL(text)
        }

        let firstPart = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        if !text.contains(where: \.isWhitespace),
           firstPart.contains(".") || firstPart == "localhost" || hasHostPort || firstPart.hasPrefix("[") {
            return try webURL("https://" + text)
        }

        return try searchEngine.searchURL(for: text)
    }

    private static func webURL(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text),
              let host = parts.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { throw AddressError.invalid }
        guard !NavigationPolicy.isRestrictedPort(parts.port) else { throw AddressError.restrictedPort }
        return url
    }
}
