import Foundation
import Testing
import WebKit
@testable import Levistica

extension WebKitIntegrationTests {
@MainActor
struct PageSafetyTests {
    private func fixture(_ path: String) throws -> URL {
        let raw = try #require(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let base = try #require(URL(string: raw))
        try #require(base.scheme == "http" && base.host == "127.0.0.1" && base.port != nil)
        return base.appendingPathComponent(path)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition())
    }
    private func seededPage() async throws -> PageRuntime {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        runtime.load(try fixture("one"))
        try await wait { runtime.webView.title == "Fixture one" }
        return runtime
    }

    @Test func threatCancelsDepartureAndPreservesThePreviousDocument() async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        let previousURL = runtime.url, revision = runtime.documentRevision
        var checks = [URL]()
        runtime.navigationSafetyCheck = { url in checks.append(url); return .threat([.socialEngineering]) }
        runtime.load(try fixture("two"))
        try await wait { runtime.safetyWarningHost != nil }
        #expect(checks.count == 1)
        #expect(runtime.webView.title == "Fixture one")
        #expect(runtime.url == previousURL && runtime.documentRevision == revision)
        runtime.dismissSafetyWarning()
        #expect(runtime.safetyWarningHost == nil)
        #expect(runtime.webView.title == "Fixture one" && runtime.url == previousURL)
    }

    @Test func successfulChecksCoverTheActionAndMainResponse() async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        var checks = [URL]()
        runtime.navigationSafetyCheck = { url in checks.append(url); return .noListedThreat }
        let destination = try fixture("two")
        runtime.load(destination)
        try await wait { runtime.webView.title == "Fixture two" }
        #expect(checks.filter { $0 == destination }.count >= 2)
        #expect(runtime.safetyWarningHost == nil)
    }

    @Test(arguments: [("redirect-two", "two"), ("redirect-download", "download")])
    func redirectDestinationAndAttachmentCannotBypassTheCheck(paths: (String, String)) async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        var checks = [String](), receivedDownload = false
        runtime.onDownload = { download in receivedDownload = true; download.cancel { _ in } }
        runtime.navigationSafetyCheck = { url in
            checks.append(url.path)
            return url.path == "/" + paths.1 ? .threat([.malware]) : .noListedThreat
        }
        runtime.load(try fixture(paths.0))
        try await wait { runtime.safetyWarningHost != nil }
        #expect(checks.contains("/" + paths.0) && checks.contains("/" + paths.1))
        #expect(runtime.webView.title == "Fixture one")
        #expect(receivedDownload == false)
    }

    @Test func subframesAreNotSentToTheProtectionService() async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent()); defer { runtime.stop() }
        var checks = [String]()
        runtime.navigationSafetyCheck = { url in checks.append(url.path); return .noListedThreat }
        runtime.webView.loadSimulatedRequest(URLRequest(url: try fixture("generated-parent")), responseHTML:
            "<title>Parent</title><iframe src='/one' onload='document.title=\"Subframe loaded\"'></iframe>")
        try await wait { runtime.webView.title == "Subframe loaded" }
        #expect(checks.contains("/one") == false)
        #expect(runtime.safetyWarningHost == nil)
    }

    @Test func stopResolvesPendingDecisionAndIgnoresItsLateThreat() async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        var started = false
        runtime.navigationSafetyCheck = { _ in
            started = true
            try? await Task.sleep(for: .milliseconds(150))
            return .threat([.malware])
        }
        runtime.load(try fixture("two"))
        try await wait { started }
        runtime.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(runtime.safetyWarningHost == nil)
        #expect(runtime.webView.title == "Fixture one")
    }

    @Test func aNewNavigationCannotBeOverwrittenByAnOldVerdict() async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        var started = false
        runtime.navigationSafetyCheck = { url in
            if url.path == "/two" {
                started = true
                try? await Task.sleep(for: .milliseconds(150))
                return .threat([.malware])
            }
            return .noListedThreat
        }
        runtime.load(try fixture("two"))
        try await wait { started }
        runtime.load(try fixture("one"))
        try await Task.sleep(for: .milliseconds(250))
        #expect(runtime.safetyWarningHost == nil)
        #expect(runtime.webView.title == "Fixture one")
    }

    @Test func unavailableProtectionDoesNotPretendToHaveFoundAThreat() async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        runtime.navigationSafetyCheck = { _ in .unavailable(.authentication) }
        runtime.load(try fixture("two"))
        try await wait { runtime.webView.title == "Fixture two" }
        #expect(runtime.safetyWarningHost == nil)
    }


    @Test(arguments: [false, true])
    func blockingAnApprovedDepartureRestoresInputProtection(blockAtResponse: Bool) async throws {
        let runtime = try await seededPage(); defer { runtime.stop() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runtime.webView.evaluateJavaScript(
                "window.webkit.messageHandlers.levisticaInputActivity.postMessage({frame: 'generated-safety-edit', revision: 1, pending: true}); true",
                in: nil, in: .world(name: "LevisticaInputActivity")) { result in
                    continuation.resume(with: result.map { _ in () })
                }
        }
        try await wait { runtime.inputGuard.needsDepartureConfirmation }
        runtime.inputGuard.approveDeparture()
        #expect(runtime.inputGuard.needsDepartureConfirmation == false)
        let originalURL = runtime.url, revision = runtime.documentRevision
        var checks = 0
        runtime.navigationSafetyCheck = { _ in
            checks += 1
            return !blockAtResponse || checks > 1 ? .threat([.socialEngineering]) : .noListedThreat
        }
        runtime.load(try fixture("two"))
        try await wait { runtime.safetyWarningHost != nil }
        #expect(checks == (blockAtResponse ? 2 : 1))
        #expect(runtime.inputGuard.needsDepartureConfirmation)
        #expect(runtime.inputGuard.hasEditedInput)
        #expect(runtime.url == originalURL && runtime.documentRevision == revision)
        runtime.dismissSafetyWarning()
        #expect(runtime.inputGuard.needsDepartureConfirmation)
        #expect(runtime.webView.title == "Fixture one")
    }

}
}
