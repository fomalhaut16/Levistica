import Foundation
import Testing
@testable import Levistica

struct SafeBrowsingURLTests {
    private let rules = """
    // Minimal fixture; the real bundle includes ICANN and private sections.
    com
    uk
    co.uk
    cn
    公司.cn
    *.ck
    !www.ck
    jp
    *.kawasaki.jp
    !city.kawasaki.jp
    github.io
    """

    @Test(arguments: [
        ("http://host/%25%32%35", "host", "/%25"),
        ("http://host/%2525252525252525", "host", "/%25"),
        ("http://host/asdf%25%32%35asd", "host", "/asdf%25asd"),
        ("http://host/a//b/../c/./", "host", "/a/c/"),
        ("http://host/a/b/..", "host", "/a/"),
        ("http://host/../../a", "host", "/a"),
        ("http://host/a%2Fb/%2E%2E/c", "host", "/a/c"),
        ("http://host/%23a#ignored", "host", "/%23a"),
        ("http://host/%00%FF%20", "host", "/%00%FF%20"),
        ("http://host/a\tb\nc\r", "host", "/abc"),
        ("https://..WWW.Example.COM...:443", "www.example.com", "/"),
        ("https://食狮.公司.cn/", "xn--85x722f.xn--55qx5d.cn", "/"),
        ("http://0xC3.0x7f.0.0xb/a", "195.127.0.11", "/a"),
        ("http://0303.0177.0.013/a", "195.127.0.11", "/a"),
        ("http://3279880203/a", "195.127.0.11", "/a"),
        ("http://127.1/", "127.0.0.1", "/"),
        ("http://[2001:0db8:0000::1]:8080/a", "[2001:db8::1]", "/a"),
        ("http://[::ffff:192.0.2.1]/", "192.0.2.1", "/"),
        ("http://[64:ff9b::c000:201]/", "192.0.2.1", "/")
    ])
    func canonicalization(input: String, host: String, path: String) throws {
        let result = try SafeBrowsingURL.canonicalize(input)
        #expect(result.host == host)
        #expect(result.path == path)
    }

    @Test func queryAndEscapedFragmentArePreservedWithoutPathNormalization() throws {
        let value = try SafeBrowsingURL.canonicalize("https://USER:PASS@EXAMPLE.com:8443/a/../b?x=/../a//b&z=%23ok#drop")
        #expect(value.host == "example.com")
        #expect(value.path == "/b")
        #expect(value.query == "x=/../a//b&z=%23ok")
    }

    @Test func suffixRulesRespectWildcardExceptionAndPrivateRegistrations() throws {
        let suffixes = try SafeBrowsingPublicSuffixes(text: rules)
        #expect(suffixes.registrableDomain("www.example.co.uk") == "example.co.uk")
        #expect(suffixes.registrableDomain("co.uk") == nil)
        #expect(suffixes.registrableDomain("b.ck") == nil)
        #expect(suffixes.registrableDomain("a.b.ck") == "a.b.ck")
        #expect(suffixes.registrableDomain("x.www.ck") == "www.ck")
        #expect(suffixes.registrableDomain("a.city.kawasaki.jp") == "city.kawasaki.jp")
        #expect(suffixes.registrableDomain("a.github.io") == "a.github.io")
        #expect(suffixes.registrableDomain("github.io") == nil)
        #expect(suffixes.registrableDomain("x.example.unknown") == "example.unknown")
        #expect(suffixes.registrableDomain("localhost") == nil)
    }

    @Test func officialExpressionExampleAndThirtyExpressionLimit() throws {
        let suffixes = try SafeBrowsingPublicSuffixes(text: rules)
        let url = try #require(URL(string: "http://a.b.com/1/2.html?param=1"))
        let expressions = try SafeBrowsingURL.expressions(for: url, suffixes: suffixes)
        #expect(Set(expressions) == Set([
            "a.b.com/1/2.html?param=1", "a.b.com/1/2.html", "a.b.com/", "a.b.com/1/",
            "b.com/1/2.html?param=1", "b.com/1/2.html", "b.com/", "b.com/1/"
        ]))
        let long = try #require(URL(string: "http://a.b.c.d.e.f.com/1/2/3/4/file?x=1"))
        let many = try SafeBrowsingURL.expressions(for: long, suffixes: suffixes)
        #expect(many.count == 30 && Set(many).count == 30)
        #expect(many.contains("b.c.d.e.f.com/") == false)
        #expect(many.contains("c.d.e.f.com/"))
        #expect(many.contains("com/") == false)
        #expect(many.contains("f.com/1/2/3/4/") == false)
    }

    @Test func privateSuffixAndIPOnlyCheckTheirOwnHost() throws {
        let suffixes = try SafeBrowsingPublicSuffixes(text: rules)
        let privateURL = try #require(URL(string: "https://a.github.io/"))
        #expect(try SafeBrowsingURL.expressions(for: privateURL, suffixes: suffixes) == ["a.github.io/"])
        let ipv4 = try #require(URL(string: "http://1.2.3.4/1/"))
        #expect(Set(try SafeBrowsingURL.expressions(for: ipv4, suffixes: suffixes)) == Set(["1.2.3.4/1/", "1.2.3.4/"]))
        let ipv6 = try #require(URL(string: "http://[2001:db8::1]/"))
        #expect(try SafeBrowsingURL.expressions(for: ipv6, suffixes: suffixes) == ["[2001:db8::1]/"])
    }

    @Test func knownExpressionHashIsExactlyThirtyTwoBytes() throws {
        let suffixes = try SafeBrowsingPublicSuffixes(text: rules)
        let url = try #require(URL(string: "https://a.example.com/"))
        let hashes = try SafeBrowsingURL.hashes(for: url, suffixes: suffixes)
        #expect(hashes.first?.map { String(format: "%02x", $0) }.joined() == "291bc5421f1cd54d99afcc55d166e2b9fe42447025895bf09dd41b2110a687dc")
        #expect(hashes.allSatisfy { $0.count == 32 })
    }

    @Test(arguments: ["", "file:///tmp/a", "javascript:alert(1)", "https://", "https://[bad]/", "https://host:abc/", "https://host:70000/", "https://host%00/", "https://host name/"])
    func malformedInputDoesNotProduceASafeLookup(input: String) {
        #expect(throws: (any Error).self) { try SafeBrowsingURL.canonicalize(input) }
    }

    @Test func workLimitsRejectInsteadOfPartiallyCanonicalizing() {
        #expect(throws: (any Error).self) { try SafeBrowsingURL.canonicalize("https://host/" + String(repeating: "a", count: 65_536)) }
        #expect(throws: (any Error).self) { try SafeBrowsingURL.canonicalize("https://host/%" + String(repeating: "25", count: 140)) }
        #expect(throws: (any Error).self) { try SafeBrowsingPublicSuffixes(text: "// no rules") }
    }

    @Test func pinnedSuffixResourceIsAvailableInsideTheRealApp() throws {
        let suffixes = try SafeBrowsingPublicSuffixes.bundled()
        #expect(suffixes.registrableDomain("www.example.co.uk") == "example.co.uk")
        #expect(suffixes.registrableDomain("a.github.io") == "a.github.io")
        #expect(suffixes.registrableDomain("xn--85x722f.xn--55qx5d.cn") == "xn--85x722f.xn--55qx5d.cn")
    }
}
