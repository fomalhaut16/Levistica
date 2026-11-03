import Foundation

enum SafeBrowsingAPIError: Error, Equatable {
    case invalidKey, invalidRequest, authentication, quota, http(Int)
    case transport, invalidResponse, responseTooLarge
}

private final class SafeBrowsingNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward the API key, even to another Google URL.
        completionHandler(nil)
    }
}

actor SafeBrowsingAPI {
    private let key: String
    private let session: URLSession

    init(key: String, configuration: URLSessionConfiguration? = nil) throws {
        guard (16...256).contains(key.utf8.count),
              key.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw SafeBrowsingAPIError.invalidKey
        }
        self.key = key
        let config = configuration?.copy() as? URLSessionConfiguration ?? .ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config, delegate: SafeBrowsingNoRedirect(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func shutdown() { session.invalidateAndCancel() }

    func fetchList(_ name: String, version: Data? = nil) async throws -> SafeBrowsingListResponse {
        guard SafeBrowsingPrefixList.names.contains(name), (version?.count ?? 0) <= 1024 else {
            throw SafeBrowsingAPIError.invalidRequest
        }
        let query = version.map { [URLQueryItem(name: "version", value: $0.base64EncodedString())] } ?? []
        let data = try await get(path: "hashList/" + name, query: query, maximumBytes: 8 * 1024 * 1024)
        let result: SafeBrowsingListResponse
        do { result = try SafeBrowsingListResponse(protobuf: data) }
        catch { throw SafeBrowsingAPIError.invalidResponse }
        guard result.update.name == name else { throw SafeBrowsingAPIError.invalidResponse }
        return result
    }

    func search(prefixes: [Data]) async throws -> SafeBrowsingHashResponse {
        guard !prefixes.isEmpty, prefixes.count <= 30, prefixes.allSatisfy({ $0.count == 4 }) else {
            throw SafeBrowsingAPIError.invalidRequest
        }
        let unique = Set(prefixes)
        let query = unique.map { $0.base64EncodedString() }.sorted().map { URLQueryItem(name: "hashPrefixes", value: $0) }
        let data = try await get(path: "hashes:search", query: query, maximumBytes: 1_048_576)
        let result: SafeBrowsingHashResponse
        do { result = try SafeBrowsingHashResponse(protobuf: data) }
        catch { throw SafeBrowsingAPIError.invalidResponse }
        guard result.matches.allSatisfy({ unique.contains(Data($0.hash.prefix(4))) }) else {
            throw SafeBrowsingAPIError.invalidResponse
        }
        return result
    }

    private func get(path: String, query: [URLQueryItem], maximumBytes: Int) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "safebrowsing.googleapis.com"
        components.path = "/v5/" + path
        if !query.isEmpty {
            components.queryItems = query
            // A '+' in standard base64 is data, not form-encoded whitespace.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw SafeBrowsingAPIError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
        do {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw SafeBrowsingAPIError.invalidResponse }
            switch http.statusCode {
            case 200: break
            case 401, 403: throw SafeBrowsingAPIError.authentication
            case 429: throw SafeBrowsingAPIError.quota
            default: throw SafeBrowsingAPIError.http(http.statusCode)
            }
            guard ["application/x-protobuf", "application/protobuf", "application/octet-stream"].contains(http.mimeType ?? "") else {
                throw SafeBrowsingAPIError.invalidResponse
            }
            guard http.expectedContentLength <= Int64(maximumBytes) else { throw SafeBrowsingAPIError.responseTooLarge }
            var data = Data()
            if http.expectedContentLength > 0 { data.reserveCapacity(min(Int(http.expectedContentLength), 1_048_576)) }
            for try await byte in bytes {
                guard data.count < maximumBytes else { throw SafeBrowsingAPIError.responseTooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as SafeBrowsingAPIError { throw error }
        catch { throw SafeBrowsingAPIError.transport } // Never export an error carrying request details.
    }
}
