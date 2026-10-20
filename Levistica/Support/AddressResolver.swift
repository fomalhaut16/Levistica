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

enum AddressResolver {
    static func resolve(_ input: String) throws -> URL {
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

        var search = URLComponents()
        search.scheme = "https"
        search.host = "duckduckgo.com"
        search.path = "/"
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = search.url else { throw AddressError.invalid }
        return url
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
