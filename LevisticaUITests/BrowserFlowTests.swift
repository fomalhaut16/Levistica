import XCTest

final class BrowserFlowTests: XCTestCase {
    @MainActor
    func testNavigationAndRestart() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        XCTAssertTrue(base.hasPrefix("http://127.0.0.1:"), "Run script/test.sh to start the isolated fixture server.")
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 15), "Fixture: \(base)\n\(app.debugDescription)")
        app.webViews.links["Blocked native link"].click()
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].exists)
        app.webViews.links["Second page"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.buttons["backButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.buttons["forwardButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.textFields["addressField"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.count, 0, "M1 starts blank and must not allocate a WebView.")
        app.terminate()
    }

    @MainActor
    func testUnsafeInputIsRejectedWithoutOpeningPage() {
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit("javascript:alert(1)", in: app)
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        app.terminate()
    }

    @MainActor
    func testUntrustedCertificateIsRejected() throws {
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_TLS_FIXTURE_URL"])
        XCTAssertTrue(url.hasPrefix("https://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(url + "/one", in: app)
        let error = app.staticTexts["errorMessage"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        let message = error.value as? String ?? error.label
        XCTAssertTrue(message.contains("安全な接続"), message)
        XCTAssertFalse(app.webViews.staticTexts["Levistica fixture one"].exists)
        app.terminate()
    }

    @MainActor
    func testNetworkFailureKeepsAddressAndOffersRetry() throws {
        let url = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FAILURE_FIXTURE_URL"])
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"))
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        let address = app.textFields["addressField"]
        submit(url + "/", in: app)
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 15), "Disconnected: \(url)\n\(app.debugDescription)")
        XCTAssertEqual(address.value as? String, url + "/")
        XCTAssertTrue(app.buttons["再試行"].exists)
        app.terminate()
    }

    @MainActor
    private func submit(_ text: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), file: file, line: line)
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText(text)
        // Verify the injected text before Return, so a lost key cannot be mistaken for a navigation failure.
        XCTAssertEqual(address.value as? String, text, file: file, line: line)
        address.typeKey(.return, modifierFlags: [])
    }
}
