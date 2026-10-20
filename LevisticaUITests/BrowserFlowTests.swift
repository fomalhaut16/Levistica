import XCTest
import AppKit

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
        let forward = app.buttons["forwardButton"]
        let forwardReady = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: forward)
        wait(for: [forwardReady], timeout: 5)
        forward.click()
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
    func testFullscreenCanEnterAndExit() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/fullscreen", in: app)
        let enter = app.webViews.buttons["Enter fullscreen"]
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        let beforeFrame = app.webViews.firstMatch.frame
        attachWindowImage(app, name: "fullscreen-before")
        enter.click()
        XCTAssertTrue(app.webViews.staticTexts["fullscreen active"].waitForExistence(timeout: 10))
        let screenSize = try XCTUnwrap(NSScreen.main?.frame.size)
        let fillsScreen = NSPredicate { _, _ in
            let frame = app.webViews.firstMatch.frame
            return frame.width >= screenSize.width - 2 && frame.height >= screenSize.height * 0.9
        }
        let fullscreenGeometry = expectation(for: fillsScreen, evaluatedWith: nil)
        wait(for: [fullscreenGeometry], timeout: 10)
        let fullImage = XCTAttachment(screenshot: app.screenshot())
        fullImage.name = "fullscreen-active"
        fullImage.lifetime = .keepAlways
        add(fullImage)
        print("Fullscreen frames: \(app.windows.allElementsBoundByIndex.map(\.frame)); webview: \(app.webViews.firstMatch.frame); before: \(beforeFrame)")
        app.webViews.buttons["Exit fullscreen"].click()
        XCTAssertTrue(app.webViews.staticTexts["windowed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["addressField"].exists)
        let afterFrame = app.webViews.firstMatch.frame
        XCTAssertEqual(afterFrame.width, beforeFrame.width, accuracy: 2)
        XCTAssertEqual(afterFrame.height, beforeFrame.height, accuracy: 2)
        attachWindowImage(app, name: "fullscreen-after")
        app.terminate()
    }

    @MainActor
    func testTabSwitchKeepsDraftAndCloseCanBeReopened() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/tab-state", in: app)
        let draft = app.webViews.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        draft.typeText("keep this draft")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.webViews.count, 0)
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "keep this draft")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.textFields["Draft"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.textFields["Draft"].value as? String, "")
        app.terminate()
    }

    @MainActor
    func testPageFindReportsMatchesAndNoMatches() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["pageFindField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.click()
        find.typeText("fixture")
        app.buttons["findNextButton"].click()
        XCTAssertTrue(app.staticTexts["見つかりました"].waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.click()
        find.typeKey("a", modifierFlags: .command)
        find.typeText("zzzz-no-match-zzzz")
        app.buttons["findNextButton"].click()
        XCTAssertTrue(app.staticTexts["見つかりません"].waitForExistence(timeout: 5))
        app.buttons["closeFindButton"].click()
        XCTAssertFalse(find.exists)
        app.terminate()
    }

    @MainActor
    func testReopeningPostDoesNotAutomaticallyLoadIt() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/post-form", in: app)
        let button = app.webViews.buttons["Submit fixture"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.webViews.staticTexts["Submission received"].waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.staticTexts["送信後のページです。URLを確認してから開いてください。"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/submitted")
        app.terminate()
    }

    @MainActor
    func testRestartRestoresTabsAndLoadsOnlyTheSelection() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 5))
        let firstRow = app.staticTexts["Fixture two"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        firstRow.rightClick()
        app.menuItems["後ろに移動"].click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3タブ・読み込み済み1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["sessionRecoveryNotice"].exists)
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3タブ・読み込み済み2"].waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    private func attachWindowImage(_ app: XCUIApplication, name: String) {
        // macOS application screenshots may include other applications. Crop to this
        // fixture window before retaining any image in the test result.
        let image = app.screenshot().image
        let frame = app.windows.firstMatch.frame
        guard let screen = NSScreen.main, !frame.isEmpty,
              let original = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scaleX = CGFloat(original.width) / screen.frame.width
        let scaleY = CGFloat(original.height) / screen.frame.height
        let region = CGRect(x: frame.minX * scaleX, y: frame.minY * scaleY,
                            width: frame.width * scaleX, height: frame.height * scaleY)
        guard let cropped = original.cropping(to: region) else { return }
        let attachment = XCTAttachment(image: NSImage(cgImage: cropped, size: frame.size))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForInputIndicator(in app: XCUIApplication) {
        // macOS briefly exposes the input-source badge as a dialog on field focus.
        // Let it disappear rather than letting XCTest try to dismiss a stale button.
        let indicator = app.dialogs.containing(.button, identifier: "InputSource").firstMatch
        XCTAssertTrue(indicator.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func submit(_ text: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        let address = app.textFields["addressField"]
        XCTAssertTrue(address.waitForExistence(timeout: 10), file: file, line: line)
        waitForInputIndicator(in: app)
        address.click()
        waitForInputIndicator(in: app)
        address.typeKey("a", modifierFlags: .command)
        address.typeText(text)
        // Verify the injected text before Return, so a lost key cannot be mistaken for a navigation failure.
        XCTAssertEqual(address.value as? String, text, file: file, line: line)
        address.typeKey(.return, modifierFlags: [])
    }
}
