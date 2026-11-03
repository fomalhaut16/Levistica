import Foundation

// Owns an explicitly started protection session. It does not choose application
// consent, storage paths or UI behavior; the normal-app owner supplies those.
actor SafeBrowsingProtection {
    enum State: Sendable, Equatable {
        case stopped, starting, ready
        case unavailable(SafeBrowsingIssue)
        case keyUnavailable(SafeBrowsingKeychainError)
    }
    struct Dependencies: Sendable {
        let readKey: @Sendable () throws -> String
        let makeRemote: @Sendable (String) throws -> any SafeBrowsingRemote
        let makeCache: @Sendable () throws -> SafeBrowsingListCache?
        let loadSuffixes: @Sendable () throws -> SafeBrowsingPublicSuffixes
    }

    private let allowed: Bool
    private let dependencies: Dependencies
    private var worker: SafeBrowsingVerifier?
    private var state: State = .stopped
    private var generation = UUID()
    private var refreshTask: Task<Void, Never>?

    init(allowed: Bool, dependencies: Dependencies) {
        self.allowed = allowed; self.dependencies = dependencies
    }
    // Creating this owner does not read a credential or create a directory.
    // Debug, Profile, Measurement and ephemeral Release cannot use the normal key.
    static func normalApplication() -> SafeBrowsingProtection {
        #if DEBUG || LEVISTICA_PROFILE || LEVISTICA_MEASUREMENT
        let allowed = false
        #else
        let environment = ProcessInfo.processInfo.environment
        let allowed = permitsCredentials(bundleIdentifier: Bundle.main.bundleIdentifier,
                                          ephemeral: environment["LEVISTICA_EPHEMERAL"],
                                          sessionTestID: environment["LEVISTICA_SESSION_TEST_ID"])
        #endif
        return SafeBrowsingProtection(allowed: allowed, dependencies: .init(
            readKey: { try SafeBrowsingKeychain.readAfterUserRequest() },
            makeRemote: { try SafeBrowsingAPI(key: $0) },
            makeCache: {
                let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
                return try SafeBrowsingListCache(directory: root.appendingPathComponent("Levistica/SafeBrowsing", isDirectory: true))
            },
            loadSuffixes: { try .bundled() }))
    }

    static func permitsCredentials(bundleIdentifier: String?, ephemeral: String?, sessionTestID: String?) -> Bool {
        bundleIdentifier == "dev.fomalhaut16.Levistica"
            && (ephemeral == nil || ephemeral == "0") && sessionTestID == nil
    }

    deinit { refreshTask?.cancel() }

    func currentState() async -> State {
        guard state != .starting, let worker else { return state }
        let token = generation
        let status = await worker.status()
        guard generation == token else { return state }
        updateState(status)
        return state
    }

    // This method may show a keychain prompt. Never call automatically at launch
    // or for a page navigation; call only after the user's explicit action.
    func startAfterUserRequest() async -> State {
        guard allowed else { state = .unavailable(.disabled); return state }
        guard !Task.isCancelled else { return state }
        guard state != .starting, worker == nil else { return state }
        let token = UUID(); generation = token; state = .starting
        do {
            let key = try dependencies.readKey()
            guard !Task.isCancelled else { state = .stopped; return state }
            let cache: SafeBrowsingListCache?
            do { cache = try dependencies.makeCache() }
            catch { state = .unavailable(.cacheUnavailable); return state }
            let remote = try dependencies.makeRemote(key)
            let candidate = SafeBrowsingVerifier(remote: remote, disk: cache, loadSuffixes: dependencies.loadSuffixes)
            worker = candidate
            let status = await candidate.refresh()
            guard generation == token else { return state }
            if Task.isCancelled { await stop(); return state }
            updateState(status)
            refreshTask = Self.refreshLoop(owner: self, generation: token)
        } catch let failure as SafeBrowsingKeychainError { state = .keyUnavailable(failure) }
        catch let failure as SafeBrowsingAPIError where failure == .invalidKey { state = .keyUnavailable(.invalidKey) }
        catch { state = .unavailable(.lookupFailed) }
        return state
    }

    func check(_ url: URL) async -> SafeBrowsingVerdict {
        guard let worker else { return .unavailable(.disabled) }
        let token = generation
        let result = await worker.check(url)
        guard generation == token else { return .unavailable(.disabled) }
        if case .unavailable(let failure) = result { state = .unavailable(failure) }
        return result
    }

    func stop() async {
        generation = UUID(); state = .stopped
        refreshTask?.cancel(); refreshTask = nil
        let previous = worker; worker = nil
        await previous?.stop()
    }

    private func refresh(generation token: UUID) async -> Bool {
        guard generation == token, let worker else { return false }
        let status = await worker.refresh()
        guard generation == token else { return false }
        updateState(status)
        return true
    }

    private func updateState(_ status: SafeBrowsingVerifier.Status) {
        if let issue = status.lastIssue { state = .unavailable(issue) }
        else { state = status.recentLists == 3 ? .ready : .unavailable(.listsUnavailable) }
    }

    nonisolated private static func refreshLoop(owner: SafeBrowsingProtection, generation: UUID) -> Task<Void, Never> {
        Task { [weak owner] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
                guard await owner?.refresh(generation: generation) == true else { return }
            }
        }
    }
}
