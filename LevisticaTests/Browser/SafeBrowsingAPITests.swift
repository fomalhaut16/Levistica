import Foundation
import Synchronization
import Testing
@testable import Levistica

// Foundation owns each protocol instance's callback sequence. Shared stubs and
// captured requests are accessed only through the Mutex; real keys are never used.
private final class SafeBrowsingMockProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var status = 200
        var headers = ["Content-Type": "application/x-protobuf"]
        var body = Data()
        var failure: URLError?
        var requests: [URLRequest] = []
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let stub = Self.state.withLock { value in value.requests.append(request); return value }
        if let error = stub.failure { client?.urlProtocol(self, didFailWithError: error); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Exercise the streaming limit independently of Content-Length.
        var offset = 0
        while offset < stub.body.count {
            let end = min(stub.body.count, offset + 16_384)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end)); offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct SafeBrowsingAPITests {
    private let syntheticKey = "Test-Safe-Browsing-12345"
    private func api(status: Int = 200, headers: [String: String] = ["Content-Type": "application/x-protobuf"],
                     body: Data = Data(), failure: URLError? = nil) throws -> SafeBrowsingAPI {
        SafeBrowsingMockProtocol.state.withLock { $0 = .init(status: status, headers: headers, body: body, failure: failure) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SafeBrowsingMockProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "unrelated=fixture", "Authorization": "unrelated-fixture"]
        return try SafeBrowsingAPI(key: syntheticKey, configuration: configuration)
    }
    private func field(_ tag: UInt8, _ bytes: [UInt8]) -> [UInt8] { [tag, UInt8(bytes.count)] + bytes }
    private func list(name: String = "se-4b") -> Data {
        Data(field(0x0a, Array(name.utf8)) + [0x12,1,1])
    }

    @Test func listRequestUsesFixedTLSHostAndHeaderOnlyKey() async throws {
        let client = try api(body: list())
        let version = Data([0xfb,0xff]) // '+/8=' must retain the '+' through query decoding.
        let response = try await client.fetchList("se-4b", version: version)
        #expect(response.update.name == "se-4b")
        let requests = SafeBrowsingMockProtocol.state.withLock { $0.requests }
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let url = try #require(request.url)
        #expect(url.scheme == "https" && url.host() == "safebrowsing.googleapis.com")
        #expect(url.path() == "/v5/hashList/se-4b")
        #expect(url.absoluteString.contains(syntheticKey) == false)
        #expect(url.absoluteString.contains("%2B"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "version", value: version.base64EncodedString())])
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "X-Goog-Api-Key") == syntheticKey)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test func searchSendsOnlyUniqueFourBytePrefixes() async throws {
        let client = try api(body: Data([0x12,2,0x08,60]))
        let prefix = Data([0,1,2,3])
        let response = try await client.search(prefixes: [prefix, prefix])
        #expect(response.matches.isEmpty && response.cacheDuration == 60)
        let requests = SafeBrowsingMockProtocol.state.withLock { $0.requests }
        #expect(requests.count == 1)
        let request = try #require(requests.first), url = try #require(request.url)
        #expect(url.path() == "/v5/hashes:search")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "hashPrefixes", value: prefix.base64EncodedString())])
        #expect(request.httpBody == nil)
    }

    @Test func invalidInputDoesNotStartANetworkRequest() async throws {
        let client = try api()
        await #expect(throws: SafeBrowsingAPIError.invalidRequest) { try await client.fetchList("../../other") }
        await #expect(throws: SafeBrowsingAPIError.invalidRequest) { try await client.fetchList("se-4b", version: Data(repeating: 0, count: 1025)) }
        for prefixes in [[], [Data([1])], [Data(repeating: 0, count: 32)], Array(repeating: Data([0,0,0,0]), count: 31)] {
            await #expect(throws: SafeBrowsingAPIError.invalidRequest) { try await client.search(prefixes: prefixes) }
        }
        #expect(SafeBrowsingMockProtocol.state.withLock { $0.requests.isEmpty })
        #expect(throws: SafeBrowsingAPIError.invalidKey) { try SafeBrowsingAPI(key: "bad\r\nInjected: value") }
        #expect(throws: SafeBrowsingAPIError.invalidKey) { try SafeBrowsingAPI(key: "") }
    }

    @Test(arguments: [401,403,429,302,500])
    func httpFailuresAreSanitized(status: Int) async throws {
        let client = try api(status: status, headers: ["Content-Type": "text/plain", "Location": "https://unrelated.invalid/"], body: Data("never expose error details".utf8))
        let error: SafeBrowsingAPIError = status == 401 || status == 403 ? .authentication : status == 429 ? .quota : .http(status)
        await #expect(throws: error) { try await client.fetchList("se-4b") }
        #expect(SafeBrowsingMockProtocol.state.withLock { $0.requests.count } == 1)
    }

    @Test func badContentAndWrongListAreRejected() async throws {
        let html = try api(headers: ["Content-Type": "text/html"], body: Data("<html>fixture</html>".utf8))
        await #expect(throws: SafeBrowsingAPIError.invalidResponse) { try await html.fetchList("se-4b") }
        let wrong = try api(body: list(name: "mw-4b"))
        await #expect(throws: SafeBrowsingAPIError.invalidResponse) { try await wrong.fetchList("se-4b") }
        let broken = try api(body: Data([0xff]))
        await #expect(throws: SafeBrowsingAPIError.invalidResponse) { try await broken.fetchList("se-4b") }
    }

    @Test func claimedAndStreamingOversizedResponsesAreRejected() async throws {
        let announced = try api(headers: ["Content-Type": "application/x-protobuf", "Content-Length": "8388609"])
        await #expect(throws: SafeBrowsingAPIError.responseTooLarge) { try await announced.fetchList("se-4b") }
        let streaming = try api(body: Data(repeating: 0, count: 1_048_577))
        await #expect(throws: SafeBrowsingAPIError.responseTooLarge) { try await streaming.search(prefixes: [Data([0,0,0,0])]) }
    }

    @Test func unrelatedReturnedHashCannotEnterTheLookupCache() async throws {
        let unrelated = field(0x0a, field(0x0a, Array(repeating: 0x42, count: 32)) + [0x12,2,0x08,2])
        let client = try api(body: Data(unrelated))
        await #expect(throws: SafeBrowsingAPIError.invalidResponse) { try await client.search(prefixes: [Data([0,0,0,0])]) }
    }

    @Test func transportFailureAndCancellationDoNotReturnRequestDetails() async throws {
        let offline = try api(failure: URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: "private request detail fixture"]))
        await #expect(throws: SafeBrowsingAPIError.transport) { try await offline.fetchList("se-4b") }
        let cancelled = try api(failure: URLError(.cancelled))
        await #expect(throws: CancellationError.self) { try await cancelled.fetchList("se-4b") }
    }
}
