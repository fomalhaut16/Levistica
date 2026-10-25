import Foundation
import Testing
@testable import Levistica

struct AddressResolverTests {
    @Test(arguments: SearchEngine.allCases)
    func chosenSearchEnginePreservesUnicodeAndQuerySymbols(_ engine: SearchEngine) throws {
        for query in ["大学 資料", "C++", "a&b#c%20"] {
            let url = try AddressResolver.resolve(query, searchEngine: engine)
            let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(parts.scheme == "https")
            #expect(parts.host == (engine == .google ? "www.google.com" : "duckduckgo.com"))
            #expect(parts.path == (engine == .google ? "/search" : "/"))
            #expect(parts.queryItems == [URLQueryItem(name: "q", value: query)])
            #expect(parts.percentEncodedQuery?.contains("+") == false)
        }
    }

    @Test(arguments: SearchEngine.allCases)
    func searchChoicePreservesAddressValidation(_ engine: SearchEngine) throws {
        #expect(try AddressResolver.resolve("example.com/path?q=a+b", searchEngine: engine).absoluteString
                == "https://example.com/path?q=a+b")
        #expect(throws: AddressError.unsupportedScheme) {
            try AddressResolver.resolve("javascript:alert(1)", searchEngine: engine)
        }
        #expect(throws: AddressError.invalid) {
            try AddressResolver.resolve("https://user:password@example.com/", searchEngine: engine)
        }
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        (" http://example.com/path ", "http://example.com/path"),
        ("localhost:8080", "https://localhost:8080"),
        ("example.com:8443/a", "https://example.com:8443/a"),
        ("https://example.com/a?q=日本語", "https://example.com/a?q=%E6%97%A5%E6%9C%AC%E8%AA%9E")
    ])
    func addresses(input: String, expected: String) throws {
        #expect(try AddressResolver.resolve(input).absoluteString == expected)
    }

    @Test(arguments: ["大学 資料", "hello world", "Swift"])
    func searchesOnlyAfterSubmission(input: String) throws {
        let url = try AddressResolver.resolve(input)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "duckduckgo.com")
        #expect(parts.queryItems?.first?.value == input)
    }

    @Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,test", "mailto:a@example.com"])
    func rejectsApplicationSchemes(input: String) {
        #expect(throws: AddressError.unsupportedScheme) { try AddressResolver.resolve(input) }
    }

    @Test(arguments: ["http://", "https://user:password@example.com", "/etc/passwd", "~/Downloads/a.pdf", "https://example.com\n/", "https://exa mple.com", "https://example.com:99999"])
    func rejectsMalformedAddresses(input: String) {
        #expect(throws: AddressError.invalid) { try AddressResolver.resolve(input) }
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: AddressError.empty) { try AddressResolver.resolve("  ") }
    }

    @Test(arguments: ["http://127.0.0.1:1/", "https://example.com:25/"])
    func explainsRestrictedPorts(input: String) {
        #expect(throws: AddressError.restrictedPort) { try AddressResolver.resolve(input) }
    }
}
