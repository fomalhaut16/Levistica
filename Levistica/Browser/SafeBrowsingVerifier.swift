import Foundation

protocol SafeBrowsingRemote: Sendable {
    func fetchList(_ name: String, version: Data?) async throws -> SafeBrowsingListResponse
    func search(prefixes: [Data]) async throws -> SafeBrowsingHashResponse
    func shutdown() async
}
extension SafeBrowsingAPI: SafeBrowsingRemote {}

enum SafeBrowsingIssue: Sendable, Equatable {
    case disabled, resources, listsUnavailable, invalidURL, authentication, quota
    case lookupFailed, cacheUnavailable, busy, cancelled
}

enum SafeBrowsingVerdict: Sendable, Equatable {
    case noListedThreat
    case threat(Set<SafeBrowsingThreat>)
    case unavailable(SafeBrowsingIssue)
}

actor SafeBrowsingVerifier {
    struct Status: Sendable {
        let loadedLists: Int
        let recentLists: Int
        let refreshing: Bool
        let lastIssue: SafeBrowsingIssue?
    }
    private struct CachedLookup: Sendable {
        let matches: [SafeBrowsingHashResponse.Match]
        let expires: ContinuousClock.Instant
    }
    private struct LookupResult: Sendable {
        let response: SafeBrowsingHashResponse
        let received: ContinuousClock.Instant
    }

    private let remote: any SafeBrowsingRemote
    private let disk: SafeBrowsingListCache?
    private let loadSuffixes: @Sendable () throws -> SafeBrowsingPublicSuffixes
    private let date: @Sendable () -> Date
    private let instant: @Sendable () -> ContinuousClock.Instant
    private let lookupTimeout: Duration
    private var suffixes: SafeBrowsingPublicSuffixes?
    private var prepared = false
    private var stopped = false
    private var refreshing = false
    private var listIssues: [String: SafeBrowsingIssue] = [:]
    private var lookupIssue: SafeBrowsingIssue?
    private var cacheFailures = Set<String>()
    private var lists: [String: SafeBrowsingSnapshot] = [:]
    private var nextListRequest: [String: ContinuousClock.Instant] = [:]
    private var requireFullRefresh = Set<String>()
    private var refreshBackoff: ContinuousClock.Instant?
    private var lookupBackoff: ContinuousClock.Instant?
    private var lookupCache: [Data: CachedLookup] = [:]
    private var pending: [Set<Data>: Task<LookupResult, any Error>] = [:]

    init(remote: any SafeBrowsingRemote, disk: SafeBrowsingListCache? = nil,
         loadSuffixes: @escaping @Sendable () throws -> SafeBrowsingPublicSuffixes = { try .bundled() },
         date: @escaping @Sendable () -> Date = { Date() },
         instant: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
         lookupTimeout: Duration = .seconds(4)) {
        self.remote = remote; self.disk = disk; self.loadSuffixes = loadSuffixes
        self.date = date; self.instant = instant; self.lookupTimeout = lookupTimeout
    }

    func status() -> Status {
        prepare()
        return Status(loadedLists: lists.count, recentLists: lists.values.filter { usable($0) }.count,
                      refreshing: refreshing, lastIssue: lastIssue)
    }

    // The owner schedules refreshes. A page check never starts a bulk download.
    @discardableResult
    func refresh() async -> Status {
        prepare()
        guard !stopped, suffixes != nil, !refreshing,
              refreshBackoff.map({ instant() >= $0 }) ?? true else { return status() }
        refreshing = true
        defer { refreshing = false }
        for name in SafeBrowsingPrefixList.names.sorted() {
            if stopped || Task.isCancelled { break }
            if let deadline = nextListRequest[name] {
                if instant() < deadline { continue }
            } else if let stored = lists[name], date() < stored.refreshAfter { continue }
            do {
                let version = requireFullRefresh.contains(name) ? nil : lists[name]?.list.version
                let response = try await remote.fetchList(name, version: version)
                guard !stopped, !Task.isCancelled else { break }
                guard response.update.name == name else { throw SafeBrowsingAPIError.invalidResponse }
                // A rejected update does not waive the server's request interval.
                nextListRequest[name] = instant().advanced(by: .seconds(response.minimumWait))
                let list = try SafeBrowsingPrefixList.applying(response.update, to: lists[name]?.list)
                let updated = date()
                let snapshot = try SafeBrowsingSnapshot(list: list, updatedAt: updated,
                                                       refreshAfter: updated.addingTimeInterval(response.minimumWait))
                lists[name] = snapshot
                requireFullRefresh.remove(name)
                listIssues[name] = nil
                nextListRequest[name] = instant().advanced(by: .seconds(response.minimumWait))
                if let disk {
                    do { try disk.save(snapshot); cacheFailures.remove(name) }
                    catch { cacheFailures.insert(name) }
                }
            } catch {
                if stopped || Task.isCancelled { break }
                if let failure = error as? SafeBrowsingListError, failure == .checksumMismatch {
                    requireFullRefresh.insert(name)
                }
                let failure = Self.classify(error)
                listIssues[name] = failure
                let wait: Double = failure == .authentication ? 1800 : failure == .quota ? 300 : 60
                refreshBackoff = instant().advanced(by: .seconds(wait))
                if failure == .authentication || failure == .quota { lookupBackoff = refreshBackoff }
                break
            }
        }
        refreshing = false
        return status()
    }

    func check(_ url: URL) async -> SafeBrowsingVerdict {
        prepare()
        guard !stopped else { return .unavailable(.disabled) }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard let suffixes else { return .unavailable(.resources) }
        let hashes: Set<Data>
        do { hashes = Set(try SafeBrowsingURL.hashes(for: url, suffixes: suffixes)) }
        catch { return .unavailable(.invalidURL) }
        let now = instant()
        lookupCache = lookupCache.filter { $0.value.expires > now }
        let prefixes = Set(hashes.map { Data($0.prefix(4)) })
        let cached = prefixes.compactMap { lookupCache[$0] }.flatMap(\.matches)
        let known = Self.threats(in: cached, for: hashes)
        if !known.isEmpty { return .threat(known) }
        var candidates = Set<Data>()
        for hash in hashes {
            let bytes = Data(hash.prefix(4))
            let number = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if lists.values.contains(where: { $0.list.contains(number) }) { candidates.insert(bytes) }
        }
        let allRecent = lists.count == 3 && lists.values.allSatisfy { usable($0) }
        if candidates.isEmpty { return allRecent ? .noListedThreat : .unavailable(.listsUnavailable) }
        let missing = candidates.filter { lookupCache[$0] == nil }
        if missing.isEmpty { return allRecent ? .noListedThreat : .unavailable(.listsUnavailable) }
        if let deadline = lookupBackoff, now < deadline { return .unavailable(lastIssue ?? .lookupFailed) }
        do {
            let result = try await resolve(Set(missing))
            guard !stopped else { return .unavailable(.disabled) }
            guard !Task.isCancelled else { return .unavailable(.cancelled) }
            let threats = Self.threats(in: result.matches, for: hashes)
            if !threats.isEmpty { return .threat(threats) }
            let stillRecent = lists.count == 3 && lists.values.allSatisfy { usable($0) }
            return stillRecent ? .noListedThreat : .unavailable(.listsUnavailable)
        } catch { return .unavailable(stopped ? .disabled : Self.classify(error)) }
    }

    func stop() async {
        stopped = true
        for task in pending.values { task.cancel() }
        pending.removeAll(); lookupCache.removeAll(); lists.removeAll()
        await remote.shutdown()
    }

    private func prepare() {
        guard !prepared, !stopped else { return }
        prepared = true
        do { suffixes = try loadSuffixes() }
        catch { return }
        if let disk {
            for name in SafeBrowsingPrefixList.names.sorted() {
                do { lists[name] = try disk.load(name) }
                catch { cacheFailures.insert(name) }
            }
        }
    }

    // A successful operation clears only its own failure. Skipping a request
    // because it is not due is not evidence that an earlier failure recovered.
    private var lastIssue: SafeBrowsingIssue? {
        if stopped { return .disabled }
        if prepared, suffixes == nil { return .resources }
        if let lookupIssue { return lookupIssue }
        for name in SafeBrowsingPrefixList.names.sorted() {
            if let failure = listIssues[name] { return failure }
        }
        return cacheFailures.isEmpty ? nil : .cacheUnavailable
    }

    private func usable(_ snapshot: SafeBrowsingSnapshot) -> Bool {
        snapshot.isRecent(at: date()) && snapshot.refreshAfter > snapshot.updatedAt
    }

    private func resolve(_ prefixes: Set<Data>) async throws -> SafeBrowsingHashResponse {
        let task: Task<LookupResult, any Error>
        let owner: Bool
        if let existing = pending[prefixes] { task = existing; owner = false }
        else {
            let cachedMatches = lookupCache.values.reduce(0) { $0 + $1.matches.count }
            let reservedPrefixes = pending.keys.reduce(0) { $0 + $1.count }
            // Each accepted response has at most 2048 hashes. Reserve room before
            // sending so valid cached responses need not be evicted before TTL.
            guard pending.count < 4, lookupCache.count + reservedPrefixes + prefixes.count <= 1024,
                  cachedMatches + (pending.count + 1) * 2048 <= 8192 else { throw SafeBrowsingIssueError.busy }
            let remote = remote, instant = instant, timeout = lookupTimeout
            task = Task {
                try await withThrowingTaskGroup(of: LookupResult.self) { group in
                    defer { group.cancelAll() }
                    group.addTask {
                        let response = try await remote.search(prefixes: Array(prefixes))
                        return LookupResult(response: response, received: instant())
                    }
                    group.addTask { try await Task.sleep(for: timeout); throw SafeBrowsingIssueError.timeout }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
            }
            pending[prefixes] = task; owner = true
        }
        defer { if owner { pending[prefixes] = nil } }
        do {
            let result = try await task.value
            guard !stopped else { throw CancellationError() }
            guard result.response.matches.allSatisfy({ prefixes.contains(Data($0.hash.prefix(4))) }) else {
                throw SafeBrowsingAPIError.invalidResponse
            }
            if owner, result.response.cacheDuration > 0 {
                let expiry = result.received.advanced(by: .seconds(result.response.cacheDuration))
                for prefix in prefixes {
                    lookupCache[prefix] = CachedLookup(matches: result.response.matches.filter { Data($0.hash.prefix(4)) == prefix }, expires: expiry)
                }
            }
            if owner { lookupIssue = nil }
            return result.response
        } catch {
            if owner, !stopped {
                let failure = Self.classify(error)
                lookupIssue = failure
                let wait: Double = failure == .authentication ? 1800 : failure == .quota ? 300 : 60
                lookupBackoff = instant().advanced(by: .seconds(wait))
            }
            throw error
        }
    }

    private static func threats(in matches: [SafeBrowsingHashResponse.Match], for hashes: Set<Data>) -> Set<SafeBrowsingThreat> {
        matches.filter { hashes.contains($0.hash) }.reduce(into: Set<SafeBrowsingThreat>()) { $0.formUnion($1.threats) }
    }
    private static func classify(_ error: any Error) -> SafeBrowsingIssue {
        if error is CancellationError { return .cancelled }
        if let api = error as? SafeBrowsingAPIError {
            if api == .authentication { return .authentication }
            if api == .quota { return .quota }
        }
        if case SafeBrowsingIssueError.busy = error { return .busy }
        return .lookupFailed
    }
}

private enum SafeBrowsingIssueError: Error { case busy, timeout }
