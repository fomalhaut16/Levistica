import Foundation
import Testing
import WebKit
@testable import Levistica

extension WebKitIntegrationTests {
@MainActor struct SiteDataLibraryTests {
    private func cookie(_ domain: String, name: String) throws -> HTTPCookie {
        try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: name,
                                           .value: "synthetic", .expires: Date().addingTimeInterval(3600)]))
    }

    @Test func storeIsNotRequestedUntilTheUserLoadsTheList() async {
        let store = WKWebsiteDataStore.nonPersistent()
        var calls = 0
        let library = SiteDataLibrary { calls += 1; return store }
        #expect(calls == 0 && library.hasLoaded == false && library.items.isEmpty)
        library.load()
        await library.flush()
        #expect(calls == 1 && library.hasLoaded && library.isBusy == false)
    }

    @Test func deletionCannotBeInterruptedByTheSessionQuitPath() async {
        let session = BrowserSession(dataStore: .nonPersistent())
        let library = session.siteDataLibrary()
        library.deleteAll()
        #expect(session.isDeletingSiteData)
        #expect(session.prepareToQuit() == false)
        await library.flush()
        #expect(session.isDeletingSiteData == false && session.prepareToQuit())
        #expect(session.loadedPageCount == 0)
    }

    @Test func unavailableOwnerDoesNotFallBackToAnotherProfile() async {
        let library = SiteDataLibrary { nil }
        library.load()
        await library.flush()
        #expect(library.hasLoaded == false && library.notice != nil && library.isBusy == false)
        library.deleteAll()
        await library.flush()
        #expect(library.isDeleting == false && library.notice != nil)
    }

    @Test func selectedAndAllDeletionLeaveOtherStoresAndInvalidSelectionsUntouched() async throws {
        let own = WKWebsiteDataStore.nonPersistent()
        let other = WKWebsiteDataStore.nonPersistent()
        await own.httpCookieStore.setCookie(try cookie("one.invalid", name: "one"))
        await own.httpCookieStore.setCookie(try cookie("two.test", name: "two"))
        await other.httpCookieStore.setCookie(try cookie("other.invalid", name: "other"))
        let library = SiteDataLibrary { own }
        library.load()
        await library.flush()
        let selected = try #require(library.items.first { $0.name == "one.invalid" })
        library.delete(UUID())
        #expect(library.items.count == 2 && library.notice != nil)
        library.delete(selected.id)
        await library.flush()
        #expect(library.items.map(\.name) == ["two.test"])
        #expect(await own.httpCookieStore.allCookies().map(\.name) == ["two"])
        library.deleteAll()
        await library.flush()
        #expect(library.totalCount == 0 && library.items.isEmpty && library.isDeleting == false)
        #expect(await own.httpCookieStore.allCookies().isEmpty)
        #expect(await other.httpCookieStore.allCookies().map(\.name) == ["other"])
    }
}
}
