import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Levistica

private actor ProtectionRemote: SafeBrowsingRemote {
    var fetchCount = 0
    var stopped = false
    var failure: SafeBrowsingAPIError?
    var delay: Duration = .zero
    func fetchList(_ name: String, version: Data?) async throws -> SafeBrowsingListResponse {
        fetchCount += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        let body = Data([0x0a, UInt8(name.utf8.count)]) + Data(name.utf8) + Data([0x12,1,1, 0x32,3,8,0x88,0x0e, 0x3a,32]) + Data(SHA256.hash(data: Data()))
        return try SafeBrowsingListResponse(protobuf: body)
    }
    func search(prefixes: [Data]) throws -> SafeBrowsingHashResponse { try SafeBrowsingHashResponse(protobuf: Data()) }
    func shutdown() { stopped = true }
    func setFailure(_ value: SafeBrowsingAPIError) { failure = value }
    func setDelay(_ value: Duration) { delay = value }
}

private final class WeakProtectionReference {
    weak var value: SafeBrowsingProtection?
    init(_ value: SafeBrowsingProtection?) { self.value = value }
}

struct SafeBrowsingProtectionTests {
    private func dependencies(_ remote: ProtectionRemote, readKey: @escaping @Sendable () throws -> String = { "synthetic_key_123456789" }) -> SafeBrowsingProtection.Dependencies {
        .init(readKey: readKey, makeRemote: { _ in remote }, makeCache: { nil },
              loadSuffixes: { try SafeBrowsingPublicSuffixes(text: "com\n") })
    }

    @Test func constructionAndDisallowedStartNeverReadAKey() async throws {
        let reads = Mutex(0), remote = ProtectionRemote()
        let owner = SafeBrowsingProtection(allowed: false, dependencies: dependencies(remote, readKey: {
            reads.withLock { $0 += 1 }; return "synthetic_key_123456789"
        }))
        #expect(await owner.currentState() == .stopped)
        #expect(await owner.startAfterUserRequest() == .unavailable(.disabled))
        #expect(reads.withLock { $0 } == 0)
        #expect(await remote.fetchCount == 0)
    }

    @Test func explicitStartReadsOnceAndOnlyVerifiedListsBecomeReady() async throws {
        let reads = Mutex(0), remote = ProtectionRemote()
        let owner = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote, readKey: {
            reads.withLock { $0 += 1 }; return "synthetic_key_123456789"
        }))
        #expect(await owner.currentState() == .stopped)
        #expect(reads.withLock { $0 } == 0)
        #expect(await owner.startAfterUserRequest() == .ready)
        #expect(await owner.startAfterUserRequest() == .ready)
        let cancelledCaller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await owner.startAfterUserRequest()
        }
        #expect(await cancelledCaller.value == .ready)
        #expect(reads.withLock { $0 } == 1)
        #expect(await remote.fetchCount == 3)
        #expect(await owner.check(URL(string: "https://example.com/")!) == .noListedThreat)
        await owner.stop()
        #expect(await owner.currentState() == .stopped)
        #expect(await remote.stopped)
    }

    @Test func deniedKeyAccessDoesNotCreateRemoteOrDownloadLists() async {
        let remote = ProtectionRemote()
        let owner = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote, readKey: { throw SafeBrowsingKeychainError.denied }))
        #expect(await owner.startAfterUserRequest() == .keyUnavailable(.denied))
        #expect(await remote.fetchCount == 0)
        #expect(await owner.check(URL(string: "https://example.com/")!) == .unavailable(.disabled))
        await owner.stop()
    }

    @Test func failedRefreshNeverReportsReady() async {
        let remote = ProtectionRemote(); await remote.setFailure(.quota)
        let owner = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote))
        #expect(await owner.startAfterUserRequest() == .unavailable(.quota))
        #expect(await remote.fetchCount == 1)
        await owner.stop()
    }

    @Test func stopDuringStartCannotResurrectTheSession() async {
        let remote = ProtectionRemote(); await remote.setDelay(.milliseconds(100))
        let owner = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote))
        let start = Task { await owner.startAfterUserRequest() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await remote.fetchCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await remote.fetchCount == 1)
        await owner.stop()
        #expect(await start.value == .stopped)
        #expect(await owner.currentState() == .stopped)
        #expect(await remote.stopped)
    }

    @Test func droppingOwnerDoesNotLeaveARefreshLoopRetainingIt() async {
        let remote = ProtectionRemote()
        var owner: SafeBrowsingProtection? = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote))
        let weakOwner = WeakProtectionReference(owner)
        #expect(await owner?.startAfterUserRequest() == .ready)
        owner = nil
        for _ in 0..<100 where weakOwner.value != nil { await Task.yield() }
        #expect(weakOwner.value == nil)
    }

    @Test func cancellingStartCannotLeaveProtectionRunning() async {
        let remote = ProtectionRemote(); await remote.setDelay(.milliseconds(100))
        let owner = SafeBrowsingProtection(allowed: true, dependencies: dependencies(remote))
        let start = Task { await owner.startAfterUserRequest() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await remote.fetchCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await remote.fetchCount == 1)
        start.cancel()
        #expect(await start.value == .stopped)
        #expect(await owner.currentState() == .stopped)
        #expect(await remote.stopped)
    }

}
