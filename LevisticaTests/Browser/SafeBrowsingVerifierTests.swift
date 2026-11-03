import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Levistica

private final class VerifierClock: Sendable {
    private struct State { var date = Date(timeIntervalSince1970: 1_000_000); var instant = ContinuousClock.now }
    private let state = Mutex(State())
    func date() -> Date { state.withLock { $0.date } }
    func instant() -> ContinuousClock.Instant { state.withLock { $0.instant } }
    func advance(_ seconds: Double) { state.withLock { $0.date += seconds; $0.instant = $0.instant.advanced(by: .seconds(seconds)) } }
}

private enum VerifierFixtures {
    static func integer(_ input: UInt64) -> Data {
        var value = input, result = Data()
        repeat { var byte = UInt8(value & 127); value >>= 7; if value != 0 { byte |= 128 }; result.append(byte) } while value != 0
        return result
    }
    static func field(_ number: UInt64, _ data: Data) -> Data { integer(number << 3 | 2) + integer(UInt64(data.count)) + data }
    static func list(_ name: String, prefix: Data?, version: UInt8 = 1, badChecksum: Bool = false) throws -> SafeBrowsingListResponse {
        let bytes = prefix ?? Data()
        var body = field(1, Data(name.utf8)) + field(2, Data([version]))
        if let prefix {
            let first = prefix.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            body += field(4, Data([8]) + integer(first))
        }
        body += field(6, Data([8]) + integer(1800))
        body += field(7, badChecksum ? Data(repeating: 0, count: 32) : Data(SHA256.hash(data: bytes)))
        return try SafeBrowsingListResponse(protobuf: body)
    }
    static func hashes(_ hash: Data? = nil, ttl: UInt64 = 300) throws -> SafeBrowsingHashResponse {
        var body = field(2, Data([8]) + integer(ttl))
        if let hash { body += field(1, field(1, hash) + field(2, Data([8,2]))) }
        return try SafeBrowsingHashResponse(protobuf: body)
    }
}

private actor VerifierRemote: SafeBrowsingRemote {
    var lists: [String: SafeBrowsingListResponse]
    var response: SafeBrowsingHashResponse
    var fetches: [(String, Data?)] = []
    var searches: [[Data]] = []
    var failure: SafeBrowsingAPIError?
    var delay: Duration = .zero
    var stopped = false
    let searchStarted: AsyncStream<Void>
    private let searchStartedSignal: AsyncStream<Void>.Continuation
    init(prefix: Data?, hash: Data? = nil, ttl: UInt64 = 300) throws {
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        searchStarted = signal.stream; searchStartedSignal = signal.continuation
        lists = try Dictionary(uniqueKeysWithValues: SafeBrowsingPrefixList.names.map {
            ($0, try VerifierFixtures.list($0, prefix: $0 == "se-4b" ? prefix : nil))
        })
        response = try VerifierFixtures.hashes(hash, ttl: ttl)
    }
    func fetchList(_ name: String, version: Data?) async throws -> SafeBrowsingListResponse {
        fetches.append((name, version)); if let failure { throw failure }; return lists[name]!
    }
    func search(prefixes: [Data]) async throws -> SafeBrowsingHashResponse {
        searches.append(prefixes)
        searchStartedSignal.yield(())
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }; return response
    }
    func shutdown() { stopped = true; searchStartedSignal.finish() }
    func setFailure(_ value: SafeBrowsingAPIError?) { failure = value }
    func setDelay(_ value: Duration) { delay = value }
    func replaceList(_ name: String, prefix: Data?, badChecksum: Bool = false) throws {
        lists[name] = try VerifierFixtures.list(name, prefix: prefix, version: 2, badChecksum: badChecksum)
    }
}

struct SafeBrowsingVerifierTests {
    private let url = URL(string: "https://fixture.example/path")!
    private func hashes() throws -> [Data] { try SafeBrowsingURL.hashes(for: url, suffixes: SafeBrowsingPublicSuffixes(text: "example\n")) }
    private func verifier(_ remote: VerifierRemote, clock: VerifierClock = VerifierClock(), timeout: Duration = .seconds(4)) -> SafeBrowsingVerifier {
        SafeBrowsingVerifier(remote: remote, loadSuffixes: { try SafeBrowsingPublicSuffixes(text: "example\n") },
                             date: { clock.date() }, instant: { clock.instant() }, lookupTimeout: timeout)
    }

    @Test func aPageCheckNeverDownloadsMissingLists() async throws {
        let remote = try VerifierRemote(prefix: nil), worker = verifier(remote)
        #expect(await worker.check(url) == .unavailable(.listsUnavailable))
        #expect(await remote.fetches.isEmpty)
        #expect(await remote.searches.isEmpty)
    }

    @Test func recentListsAvoidUnnecessaryRemoteLookupsAndHonorRefreshWait() async throws {
        let clock = VerifierClock(), remote = try VerifierRemote(prefix: nil), worker = verifier(remote, clock: clock)
        #expect(await worker.refresh().recentLists == 3)
        #expect(await worker.check(url) == .noListedThreat)
        _ = await worker.refresh()
        #expect(await remote.fetches.count == 3)
        #expect(await remote.searches.isEmpty)
        clock.advance(1800)
        _ = await worker.refresh()
        let requests = await remote.fetches
        #expect(requests.count == 6)
        #expect(requests.suffix(3).allSatisfy { $0.1 == Data([1]) })
    }

    @Test func prefixCollisionDoesNotBlockWithoutExactFullHash() async throws {
        let full = try #require(hashes().first)
        var collision = full; collision[31] ^= 1
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: collision), worker = verifier(remote)
        _ = await worker.refresh()
        #expect(await worker.check(url) == .noListedThreat)
        let requests = await remote.searches
        #expect(requests.count == 1 && requests[0] == [Data(full.prefix(4))])
    }

    @Test func exactFullHashBlocksAndReusesPositiveCacheUntilExpiry() async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: full), worker = verifier(remote, clock: clock)
        _ = await worker.refresh()
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        clock.advance(299)
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        #expect(await remote.searches.count == 1)
        clock.advance(1)
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        #expect(await remote.searches.count == 2)
    }

    @Test func negativeCacheIsAlsoKeptUntilItsServerExpiry() async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4))), worker = verifier(remote, clock: clock)
        _ = await worker.refresh()
        #expect(await worker.check(url) == .noListedThreat)
        clock.advance(299)
        #expect(await worker.check(url) == .noListedThreat)
        #expect(await remote.searches.count == 1)
        clock.advance(1)
        #expect(await worker.check(url) == .noListedThreat)
        #expect(await remote.searches.count == 2)
    }

    @Test func positiveCacheTakesPrecedenceAfterLocalPrefixRemoval() async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: full, ttl: 3600), worker = verifier(remote, clock: clock)
        _ = await worker.refresh()
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        clock.advance(1800)
        try await remote.replaceList("se-4b", prefix: nil)
        _ = await worker.refresh()
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        #expect(await remote.searches.count == 1)
    }

    @Test func concurrentIdenticalChecksShareOneLookup() async throws {
        let full = try #require(hashes().first)
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: full), worker = verifier(remote)
        await remote.setDelay(.milliseconds(100))
        _ = await worker.refresh()
        async let first = worker.check(url)
        async let second = worker.check(url)
        let results = await [first, second]
        #expect(results == [.threat([.socialEngineering]), .threat([.socialEngineering])])
        #expect(await remote.searches.count == 1)
    }

    @Test(arguments: [SafeBrowsingAPIError.authentication, .quota, .transport])
    func lookupFailureIsUnavailableAndBackedOff(error: SafeBrowsingAPIError) async throws {
        let full = try #require(hashes().first)
        let remote = try VerifierRemote(prefix: Data(full.prefix(4))), worker = verifier(remote)
        _ = await worker.refresh(); await remote.setFailure(error)
        let expected: SafeBrowsingIssue = error == .authentication ? .authentication : error == .quota ? .quota : .lookupFailed
        #expect(await worker.check(url) == .unavailable(expected))
        #expect(await worker.check(url) == .unavailable(expected))
        #expect(await remote.searches.count == 1)
    }

    @Test func expiredListsDoNotTurnNegativeResultsIntoSafetyClaims() async throws {
        let clock = VerifierClock(), remote = try VerifierRemote(prefix: nil), worker = verifier(remote, clock: clock)
        _ = await worker.refresh(); clock.advance(86_401)
        #expect(await worker.check(url) == .unavailable(.listsUnavailable))
        #expect(await worker.status().recentLists == 0)
    }

    @Test func checksumFailurePreservesOldListAndNextRequestAsksForFullUpdate() async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: full), worker = verifier(remote, clock: clock)
        _ = await worker.refresh(); clock.advance(1800)
        try await remote.replaceList("mw-4b", prefix: nil, badChecksum: true)
        #expect(await worker.refresh().loadedLists == 3)
        _ = await worker.refresh()
        #expect(await remote.fetches.count == 4)
        #expect(await worker.check(url) == .threat([.socialEngineering]))
        clock.advance(60)
        _ = await worker.refresh()
        #expect(await remote.fetches.filter { $0.0 == "mw-4b" }.count == 2)
        clock.advance(1740)
        try await remote.replaceList("mw-4b", prefix: nil)
        _ = await worker.refresh()
        let requests = await remote.fetches
        let recovery = try #require(requests.dropFirst(4).first { $0.0 == "mw-4b" })
        #expect(recovery.0 == "mw-4b" && recovery.1 == nil)
    }

    @Test func invalidURLOrMissingResourcesDoNotQueryTheService() async throws {
        let remote = try VerifierRemote(prefix: nil), worker = verifier(remote)
        #expect(await worker.check(URL(string: "file:///fixture")!) == .unavailable(.invalidURL))
        let broken = SafeBrowsingVerifier(remote: remote, loadSuffixes: { throw SafeBrowsingAPIError.invalidResponse })
        #expect(await broken.check(url) == .unavailable(.resources))
        #expect(await broken.refresh().loadedLists == 0)
        #expect(await remote.searches.isEmpty)
        #expect(await remote.fetches.isEmpty)
    }

    @Test func timeoutCancelsLookupAndStopDisablesFutureWork() async throws {
        let full = try #require(hashes().first)
        let remote = try VerifierRemote(prefix: Data(full.prefix(4))), worker = verifier(remote, timeout: .milliseconds(20))
        _ = await worker.refresh(); await remote.setDelay(.seconds(10))
        #expect(await worker.check(url) == .unavailable(.lookupFailed))
        await worker.stop()
        #expect(await remote.stopped)
        #expect(await worker.check(url) == .unavailable(.disabled))
        #expect(await worker.refresh().loadedLists == 0)
        #expect(await remote.searches.count == 1)
    }

    @Test func stoppingAnInFlightLookupCannotPublishAThreatAfterShutdown() async throws {
        let full = try #require(hashes().first)
        let remote = try VerifierRemote(prefix: Data(full.prefix(4)), hash: full), worker = verifier(remote, timeout: .seconds(30))
        _ = await worker.refresh(); await remote.setDelay(.seconds(10))
        let task = Task { await worker.check(url) }
        let signal = remote.searchStarted
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in signal { return true }
                return false
            }
            group.addTask {
                do { try await Task.sleep(for: .seconds(5)) } catch { return false }
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
        #expect(observed)
        #expect(await remote.searches.count == 1)
        await worker.stop()
        #expect(await task.value == .unavailable(.disabled))
        #expect(await worker.status().loadedLists == 0)
    }

    @Test func authenticationFailureBacksOffBothRefreshAndLookup() async throws {
        let clock = VerifierClock(), remote = try VerifierRemote(prefix: nil), worker = verifier(remote, clock: clock)
        await remote.setFailure(.authentication)
        #expect(await worker.refresh().lastIssue == .authentication)
        _ = await worker.refresh(); clock.advance(1799); _ = await worker.refresh()
        #expect(await remote.fetches.count == 1)
        clock.advance(1); await remote.setFailure(nil)
        #expect(await worker.refresh().recentLists == 3)
        #expect(await remote.fetches.count == 4)
        #expect(await worker.status().refreshing == false)
    }

    @Test(arguments: [SafeBrowsingAPIError.authentication, .quota, .transport])
    func lookupFailureSurvivesListRefreshUntilAnActualLookupSucceeds(error: SafeBrowsingAPIError) async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4))), worker = verifier(remote, clock: clock)
        let expected: SafeBrowsingIssue = error == .authentication ? .authentication : error == .quota ? .quota : .lookupFailed
        _ = await worker.refresh(); await remote.setFailure(error)
        #expect(await worker.check(url) == .unavailable(expected))
        _ = await worker.refresh()
        #expect(await worker.status().lastIssue == expected)
        #expect(await worker.check(url) == .unavailable(expected))
        #expect(await remote.fetches.count == 3)
        #expect(await remote.searches.count == 1)
        clock.advance(1800); await remote.setFailure(nil)
        _ = await worker.refresh()
        #expect(await worker.status().lastIssue == expected)
        #expect(await remote.fetches.count == 6)
        #expect(await worker.check(url) == .noListedThreat)
        #expect(await worker.status().lastIssue == nil)
        #expect(await remote.searches.count == 2)
    }

    @Test func aFailedListKeepsItsIssueWhenOnlyOtherListsCanRefresh() async throws {
        let full = try #require(hashes().first), clock = VerifierClock()
        let remote = try VerifierRemote(prefix: Data(full.prefix(4))), worker = verifier(remote, clock: clock)
        _ = await worker.refresh(); clock.advance(1800)
        try await remote.replaceList("mw-4b", prefix: nil, badChecksum: true)
        #expect(await worker.refresh().lastIssue == .lookupFailed)
        clock.advance(60)
        _ = await worker.refresh()
        #expect(await worker.status().lastIssue == .lookupFailed)
        #expect(await remote.fetches.count == 6)
        #expect(await worker.check(url) == .unavailable(.listsUnavailable))
        #expect(await remote.searches.count == 1)
        #expect(await worker.status().lastIssue == .lookupFailed)
        clock.advance(1740)
        try await remote.replaceList("mw-4b", prefix: nil)
        #expect(await worker.refresh().lastIssue == nil)
    }

    @Test func cacheWriteFailureRemainsUntilTheFailedFilesAreSaved() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("verifier-cache-" + UUID().uuidString, isDirectory: true)
        let disk = try SafeBrowsingListCache(directory: directory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let clock = VerifierClock(), remote = try VerifierRemote(prefix: nil)
        let worker = SafeBrowsingVerifier(remote: remote, disk: disk,
            loadSuffixes: { try SafeBrowsingPublicSuffixes(text: "example\n") },
            date: { clock.date() }, instant: { clock.instant() })
        #expect(await worker.refresh().lastIssue == .cacheUnavailable)
        #expect(await worker.status().loadedLists == 3)
        #expect(await worker.refresh().lastIssue == .cacheUnavailable)
        #expect(await remote.fetches.count == 3)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        clock.advance(1800)
        #expect(await worker.refresh().lastIssue == nil)
        for name in SafeBrowsingPrefixList.names { #expect(try disk.load(name) != nil) }
    }


    @Test func restartKeepsTheFullUpdateRequirementAndServerWait() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("verifier-restart-" + UUID().uuidString, isDirectory: true)
        let disk = try SafeBrowsingListCache(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = VerifierClock(), firstRemote = try VerifierRemote(prefix: nil)
        func worker(_ remote: VerifierRemote) -> SafeBrowsingVerifier {
            SafeBrowsingVerifier(remote: remote, disk: disk,
                loadSuffixes: { try SafeBrowsingPublicSuffixes(text: "example\n") },
                date: { clock.date() }, instant: { clock.instant() })
        }
        let first = worker(firstRemote)
        _ = await first.refresh()
        let original = try disk.load("mw-4b")
        let originalDate = try #require(original?.updatedAt)
        clock.advance(1800)
        try await firstRemote.replaceList("mw-4b", prefix: nil, badChecksum: true)
        #expect(await first.refresh().lastIssue == .lookupFailed)
        await first.stop()
        let savedValue = try disk.load("mw-4b")
        let saved = try #require(savedValue)
        #expect(saved.requiresFullUpdate && saved.updatedAt == originalDate)
        let secondRemote = try VerifierRemote(prefix: nil), second = worker(secondRemote)
        #expect(await second.status().recentLists == 2)
        #expect(await second.status().lastIssue == .lookupFailed)
        _ = await second.refresh()
        #expect(await secondRemote.fetches.contains { $0.0 == "mw-4b" } == false)
        #expect(await second.check(url) == .unavailable(.listsUnavailable))
        clock.advance(1800)
        #expect(await second.refresh().lastIssue == nil)
        let requests = await secondRemote.fetches
        let reset = try #require(requests.first { $0.0 == "mw-4b" })
        #expect(reset.1 == nil)
        let recovered = try disk.load("mw-4b")
        #expect(recovered?.requiresFullUpdate == false)
        await second.stop()
    }

}
