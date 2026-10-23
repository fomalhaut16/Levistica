import XCTest
import AppKit

final class BrowserFlowTests: XCTestCase {
    @MainActor
    func testNewTabPageSettingAppliesToPlusAndCommandTAndSurvivesRestart() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].waitForExistence(timeout: 10))
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        func openGeneral() {
            app.typeKey(",", modifierFlags: .command)
            XCTAssertTrue(app.buttons["一般"].waitForExistence(timeout: 10))
            app.buttons["一般"].click()
            XCTAssertTrue(app.textFields["newTabPageField"].waitForExistence(timeout: 5))
        }
        func closeSettings() {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
        }
        openGeneral()
        app.buttons["useGoogleNewTabButton"].click()
        let field = app.textFields["newTabPageField"]
        XCTAssertEqual(field.value as? String, "https://www.google.com/")
        field.click()
        waitForInputIndicator(in: app)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(base + "/one")
        waitForInputIndicator(in: app)
        app.buttons["saveNewTabPageButton"].click()
        XCTAssertTrue(app.staticTexts["設定を保存しました。次に追加するタブから適用します。"].waitForExistence(timeout: 5))
        attachWindowImage(app, name: "new-tab-page-settings", knownFrame: settings.frame)
        closeSettings()
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].exists)
        app.buttons["newTabButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].exists)
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/two")
        app.typeKey("t", modifierFlags: .command)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["3タブ・読み込み済み2"].exists)
        openGeneral()
        XCTAssertEqual(field.value as? String, base + "/one")
        field.click()
        waitForInputIndicator(in: app)
        field.typeKey("a", modifierFlags: .command)
        field.typeText("file:///private/synthetic")
        waitForInputIndicator(in: app)
        app.buttons["saveNewTabPageButton"].click()
        XCTAssertTrue(app.staticTexts["HTTPまたはHTTPSのURLを入力してください。空欄にすると空白ページになります。"].waitForExistence(timeout: 5))
        closeSettings()
        app.buttons["newTabButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["4タブ・読み込み済み3"].exists)
        openGeneral()
        app.buttons["useBlankNewTabButton"].click()
        app.buttons["saveNewTabPageButton"].click()
        closeSettings()
        app.buttons["newTabButton"].click()
        XCTAssertTrue(app.staticTexts["5タブ・読み込み済み3"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.staticTexts["5タブ・読み込み済み0"].waitForExistence(timeout: 10))
        app.buttons["newTabButton"].click()
        XCTAssertTrue(app.staticTexts["6タブ・読み込み済み0"].waitForExistence(timeout: 5))
        attachWindowImage(app, name: "new-tab-page-blank-restart")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    // Opt-in only: attach to the canonical entrypoint's already running Profile app.
    @MainActor
    func testProfileSleepWorkload() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEVISTICA_PROFILE_WORKLOAD"],
              !path.isEmpty, !path.hasPrefix("$(") else {
            throw XCTSkip("Run script/test.sh --profile-ui for this diagnostic workload.")
        }
        continueAfterFailure = false
        executionTimeAllowance = 180
        struct Workload: Decodable {
            let pid: Int32
            let executable: String
            let urls: [String: String]
            let mallocStacks: Bool
            struct Collector: Decodable { let url: URL; let token: String }
            let collector: Collector?
        }
        let workload = try JSONDecoder().decode(Workload.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(workload.urls.count, 5)
        for number in 1...5 {
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(workload.urls[String(number)])))
            XCTAssertEqual(url.scheme, "http")
            XCTAssertEqual(url.host, "document-\(number).localhost")
            XCTAssertEqual(url.path, "/document/\(number)")
            XCTAssertNotNil(url.port)
            XCTAssertNil(url.user)
            XCTAssertNil(url.password)
        }
        let app = XCUIApplication(bundleIdentifier: "dev.fomalhaut16.Levistica.profile")
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground)
        let running = try XCTUnwrap(NSRunningApplication(processIdentifier: workload.pid))
        func identityMatches() -> Bool {
            let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.fomalhaut16.Levistica.profile")
            return !running.isTerminated && candidates.count == 1
                && candidates.first?.processIdentifier == workload.pid
                && running.executableURL?.path == workload.executable
        }
        XCTAssertTrue(identityMatches())
        func capture(_ stage: String) async throws {
            guard workload.mallocStacks else { return }
            XCTAssertTrue(identityMatches())
            let collector = try XCTUnwrap(workload.collector)
            XCTAssertEqual(collector.url.scheme, "http")
            XCTAssertEqual(collector.url.host, "127.0.0.1")
            XCTAssertNotNil(collector.url.port)
            XCTAssertNil(collector.url.user)
            XCTAssertNil(collector.url.password)
            var request = URLRequest(url: collector.url.appendingPathComponent("snapshot/" + stage))
            request.httpMethod = "POST"
            request.setValue(collector.token, forHTTPHeaderField: "X-Levistica-Diagnostic")
            request.timeoutInterval = 25
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            struct Reply: Decodable { let success: Bool }
            XCTAssertTrue(try JSONDecoder().decode(Reply.self, from: data).success)
            XCTAssertTrue(identityMatches())
        }
        defer {
            if identityMatches() && app.state != .notRunning { app.terminate() }
        }
        app.activate()
        XCTAssertTrue(identityMatches())
        for number in 1...5 {
            if number > 1 { app.typeKey("t", modifierFlags: .command) }
            submit(try XCTUnwrap(workload.urls[String(number)]), in: app)
            XCTAssertTrue(app.webViews.staticTexts["Levistica documents \(number)"].waitForExistence(timeout: 10))
        }
        XCTAssertTrue(app.staticTexts["5タブ・読み込み済み5"].waitForExistence(timeout: 5))
        try await capture("loaded-five")
        for cycle in 1...2 {
            for _ in 1...4 { app.typeKey("[", modifierFlags: [.command, .shift]) }
            for number in 1...4 {
                XCTAssertTrue(identityMatches())
                pageMenu("このタブを休眠…", in: app)
                let confirm = app.sheets.buttons["状態を破棄して休眠"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.click()
                XCTAssertTrue(app.buttons["resumeSleepingTabButton"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["5タブ・読み込み済み\(5 - number)"].exists)
                app.typeKey("]", modifierFlags: [.command, .shift])
            }
            XCTAssertTrue(app.webViews.staticTexts["Levistica documents 5"].waitForExistence(timeout: 10))
            try await capture("sleep-\(cycle)")
            for number in stride(from: 4, through: 1, by: -1) {
                app.typeKey("[", modifierFlags: [.command, .shift])
                XCTAssertTrue(app.webViews.staticTexts["Levistica documents \(number)"].waitForExistence(timeout: 10))
            }
            for _ in 1...4 { app.typeKey("]", modifierFlags: [.command, .shift]) }
            XCTAssertTrue(app.staticTexts["5タブ・読み込み済み5"].waitForExistence(timeout: 5))
        }
        try await capture("resumed-two")
        XCTAssertTrue(identityMatches())
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testBackupRecoveryKeepsCancelStateAndWaitsForPageSelection() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launchEnvironment["LEVISTICA_RECOVERY_FIXTURE"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_FIXTURE_BASE"] = base
        app.launch()
        app.activate()
        let restore = app.buttons["restoreSessionBackupButton"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sessionBackupInfo"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        attachWindowImage(app, name: "session-backup-offer")
        restore.click()
        let confirm = app.sheets.buttons["confirmRestoreSessionBackupButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        attachWindowImage(app, name: "session-backup-confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(restore.exists)
        XCTAssertEqual(app.webViews.count, 0)
        restore.click()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(app.staticTexts["storageFailure"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["sessionRecoveryNotice"].exists)
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み0"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/one")
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.staticTexts["ページはまだ読み込んでいません"].exists)
        attachWindowImage(app, name: "session-backup-restored-list")
        app.buttons["選択中のページを開く"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].exists)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["storageFailure"].exists)
        XCTAssertFalse(app.staticTexts["sessionRecoveryNotice"].exists)
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].exists)
        attachWindowImage(app, name: "session-backup-restart")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testFiftyAndOneHundredTabsRestoreAndSearchWithoutLoadingEveryPage() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        for count in [50, 100] {
            let app = XCUIApplication()
            app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
            app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
            app.launchEnvironment["LEVISTICA_SESSION_FIXTURE_BASE"] = base
            app.launchEnvironment["LEVISTICA_LARGE_SESSION_FIXTURE"] = String(count)
            app.launch()
            app.activate()
            XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["\(count)タブ・読み込み済み1"].exists)
            let search = app.textFields["tabSearchField"]
            search.click()
            waitForInputIndicator(in: app)
            let lastTitle = String(format: "Scale tab %03d", count)
            search.typeText(lastTitle)
            waitForInputIndicator(in: app)
            let lastTab = app.outlines.staticTexts[lastTitle].firstMatch
            XCTAssertTrue(lastTab.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["\(count)タブ・読み込み済み1"].exists)
            XCTAssertTrue(lastTab.isHittable)
            lastTab.click()
            let address = app.textFields["addressField"]
            let selectedURL = base + "/one#tab-\(count)"
            let selected = expectation(for: NSPredicate(format: "value == %@", selectedURL), evaluatedWith: address)
            wait(for: [selected], timeout: 10)
            XCTAssertTrue(app.staticTexts["\(count)タブ・読み込み済み2"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
            XCTAssertEqual(search.value as? String, "")
            let visibleSelection = app.outlines.staticTexts["Fixture one"].firstMatch
            let selectionInView = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: visibleSelection)
            wait(for: [selectionInView], timeout: 5)
            attachWindowImage(app, name: "large-session-\(count)-selected", knownFrame: app.windows["browser"].frame)
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            app.launch()
            app.activate()
            XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.textFields["addressField"].value as? String, selectedURL)
            XCTAssertTrue(app.staticTexts["\(count)タブ・読み込み済み1"].exists)
            XCTAssertFalse(app.staticTexts["sessionRecoveryNotice"].exists)
            XCTAssertFalse(app.staticTexts["storageFailure"].exists)
            let restoredSelection = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: visibleSelection)
            wait(for: [restoredSelection], timeout: 5)
            attachWindowImage(app, name: "large-session-\(count)-restart", knownFrame: app.windows["browser"].frame)
            app.typeKey("q", modifierFlags: .command)
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
    }

    @MainActor
    func testManualSleepKeepsCancelStateAndRestoresOnlyByReloading() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/sleep-state", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].waitForExistence(timeout: 10))
        app.webViews.buttons["Change page marker"].click()
        pageMenu("このタブを保持", in: app)
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["保持する設定のタブです。休眠するには保持を解除してください。"].waitForExistence(timeout: 5))
        pageMenu("タブの保持を解除", in: app)
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        attachWindowImage(app, name: "tab-sleep-confirmation")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Transient marker"].exists)
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].exists)
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        app.sheets.buttons["状態を破棄して休眠"].click()
        XCTAssertTrue(app.buttons["resumeSleepingTabButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/sleep-state")
        XCTAssertFalse(app.webViews.firstMatch.exists)
        attachWindowImage(app, name: "tab-sleep-placeholder")
        app.buttons["resumeSleepingTabButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Fresh page"].exists)
        XCTAssertFalse(app.buttons["backButton"].isEnabled)
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        app.sheets.buttons["状態を破棄して休眠"].click()
        XCTAssertTrue(app.buttons["resumeSleepingTabButton"].waitForExistence(timeout: 5))
        app.typeKey("t", modifierFlags: .command)
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 3"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testSleepingAndKeptStateSurviveRestartWithoutLoading() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        submit(base + "/sleep-state", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].waitForExistence(timeout: 10))
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        app.sheets.buttons["状態を破棄して休眠"].click()
        XCTAssertTrue(app.buttons["resumeSleepingTabButton"].waitForExistence(timeout: 5))
        pageMenu("このタブを保持", in: app)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["resumeSleepingTabButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].exists)
        pageMenu("タブの保持を解除", in: app)
        app.buttons["resumeSleepingTabButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Sleep fixture"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testManualSleepRejectsEditedInputAndPostResponse() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/tab-state", in: app)
        let draft = app.webViews.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("synthetic sleep draft")
        XCTAssertTrue(app.images.matching(identifier: "入力操作あり").firstMatch.waitForExistence(timeout: 5))
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["入力操作のあったタブは休眠しません。保存・送信後にページを開き直してください。"].waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "synthetic sleep draft")
        app.typeKey("t", modifierFlags: .command)
        submit(base + "/post-form", in: app)
        XCTAssertTrue(app.webViews.buttons["Submit fixture"].waitForExistence(timeout: 10))
        app.webViews.buttons["Submit fixture"].click()
        XCTAssertTrue(app.webViews.staticTexts["Submission received"].waitForExistence(timeout: 10))
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["URLから安全に読み込み直せることを確認できないため、休眠しません。"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Submission received"].exists)
        XCTAssertFalse(app.sheets.buttons["状態を破棄して休眠"].exists)
        app.terminate()
    }

    @MainActor
    func testUnsubmittedAddressBlocksSleepUntilEscapeRestoresThePageURL() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/sleep-state", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].waitForExistence(timeout: 10))
        let address = app.textFields["addressField"]
        address.click()
        address.typeKey("a", modifierFlags: .command)
        address.typeText("https://example.invalid/unfinished-address")
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["URL欄を編集中です。ページに戻ってから操作してください。"].waitForExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "https://example.invalid/unfinished-address")
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].exists)
        address.click()
        address.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(address.value as? String, base + "/sleep-state")
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        app.sheets.buttons["ページに戻る"].click()
        app.terminate()
    }

    @MainActor
    func testSleepRejectsMediaAndRechecksPlaybackAfterConfirmation() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/sleep-media", in: app)
        XCTAssertTrue(app.webViews.buttons["Play muted media"].waitForExistence(timeout: 10))
        app.webViews.buttons["Play muted media"].click()
        XCTAssertTrue(app.webViews.staticTexts["Muted media playing"].waitForExistence(timeout: 20))
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["ページの状態を確認できないか、メディアや保護対象があります。休眠を取り消しました。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeSleepingTabButton"].exists)
        submit(base + "/sleep-state", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Sleep loads: 1"].waitForExistence(timeout: 10))
        // A fresh document initially has no media; its timer starts while the
        // native sheet is open, so the final probe must refuse the discard.
        submit(base + "/sleep-media", in: app)
        XCTAssertTrue(app.webViews.buttons["Schedule muted media"].waitForExistence(timeout: 10))
        app.webViews.buttons["Schedule muted media"].click()
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.sheets.buttons["状態を破棄して休眠"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.staticTexts["Muted media playing"].waitForExistence(timeout: 20))
        app.sheets.buttons["状態を破棄して休眠"].click()
        XCTAssertTrue(app.staticTexts["ページの状態が変わったため、休眠を取り消しました。"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["resumeSleepingTabButton"].exists)
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.terminate()
    }

    @MainActor
    private func pageMenu(_ title: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["ページ"].click()
        app.menuBars.menuItems[title].click()
    }

    @MainActor
    func testSiteDataSettingsConfirmDomainAndClearWithoutReloadingTheDraft() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let other = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/site-data-set", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Storage present"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: .command)
        submit(other + "/site-data-set", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Cookie present"].waitForExistence(timeout: 10))
        let draft = app.webViews.textFields["Storage draft"]
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("keep this settings draft")
        waitForInputIndicator(in: app)
        app.typeKey(",", modifierFlags: .command)
        let dataTab = app.buttons["サイトデータ"]
        XCTAssertTrue(dataTab.waitForExistence(timeout: 10))
        dataTab.click()
        app.buttons["loadSiteDataButton"].click()
        let list = app.descendants(matching: .any).matching(identifier: "siteDataList").firstMatch
        let first = list.staticTexts["127.0.0.1"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(list.staticTexts["localhost"].firstMatch.exists)
        first.click()
        app.buttons["deleteSelectedSiteDataButton"].click()
        XCTAssertTrue((app.staticTexts["siteDataConfirmation"].value as? String ?? app.staticTexts["siteDataConfirmation"].label).contains("127.0.0.1"))
        attachWindowImage(app, name: "site-data-confirmation", knownFrame: app.windows.containing(.button, identifier: "loadSiteDataButton").firstMatch.frame)
        app.buttons["cancelSiteDataRemovalButton"].click()
        XCTAssertTrue(first.exists)
        app.buttons["deleteSelectedSiteDataButton"].click()
        app.buttons["confirmSiteDataRemovalButton"].click()
        XCTAssertTrue(first.waitForNonExistence(timeout: 10))
        XCTAssertTrue(list.staticTexts["localhost"].firstMatch.exists)
        let settings = app.windows.containing(.button, identifier: "loadSiteDataButton").firstMatch
        attachWindowImage(app, name: "site-data-settings", knownFrame: settings.frame)
        app.buttons["deleteAllSiteDataButton"].click()
        app.buttons["confirmSiteDataRemovalButton"].click()
        XCTAssertTrue(app.staticTexts["0件・表示は先頭1000件まで"].waitForExistence(timeout: 10))
        settings.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertEqual(draft.value as? String, "keep this settings draft")
        app.webViews.buttons["Check saved data"].click()
        XCTAssertTrue(app.webViews.staticTexts["Cookie absent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Storage absent"].waitForExistence(timeout: 10))
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/site-data-set")
        XCTAssertTrue(app.webViews.staticTexts["Site data fixture"].waitForExistence(timeout: 10))
        app.webViews.buttons["Check saved data"].click()
        XCTAssertTrue(app.webViews.staticTexts["Cookie absent"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Storage absent"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testHistorySettingsPausePersistConfirmRetentionAndResume() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["履歴"].waitForExistence(timeout: 10))
        app.buttons["履歴"].click()
        let toggle = app.checkBoxes["recordHistoryToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let ready = NSPredicate { _, _ in toggle.isEnabled }
        expectation(for: ready, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        toggle.click()
        let paused = NSPredicate { _, _ in ((toggle.value as? NSNumber)?.intValue == 0 || (toggle.value as? String) == "0") && toggle.isEnabled }
        expectation(for: paused, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        app.buttons["サイトデータ"].click()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settings.waitForNonExistence(timeout: 5), "Cmd-W in Settings must close Settings, not a browser tab")
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].waitForExistence(timeout: 5))
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["履歴の記録は停止中"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1件表示"].waitForExistence(timeout: 10))
        app.buttons["historySettingsLink"].click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let period = app.popUpButtons["historyRetentionPicker"]
        period.click()
        app.menuItems["7日"].click()
        XCTAssertTrue(app.buttons["confirmHistoryRetentionButton"].waitForExistence(timeout: 5))
        attachWindowImage(app, name: "history-settings-confirmation", knownFrame: settings.frame)
        app.buttons["cancelHistoryRetentionButton"].click()
        XCTAssertTrue((period.value as? String)?.contains("90") == true)
        period.click()
        app.menuItems["7日"].click()
        app.buttons["confirmHistoryRetentionButton"].click()
        let changed = NSPredicate { _, _ in (period.value as? String)?.contains("7") == true && period.isEnabled }
        expectation(for: changed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        attachWindowImage(app, name: "history-settings", knownFrame: settings.frame)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.buttons["履歴"].waitForExistence(timeout: 10))
        app.buttons["履歴"].click()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        expectation(for: paused, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertTrue((period.value as? String)?.contains("7") == true)
        toggle.click()
        let resumed = NSPredicate { _, _ in ((toggle.value as? NSNumber)?.intValue == 1 || (toggle.value as? String) == "1") && toggle.isEnabled }
        expectation(for: resumed, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        settings.buttons[XCUIIdentifierCloseWindow].click()
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["2件表示"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testSameDocumentRoutesAreRecordedWithoutResurrectingDeletedHistory() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/spa", in: app)
        XCTAssertTrue(app.webViews.staticTexts["SPA fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["1件表示"].waitForExistence(timeout: 10))
        app.webViews.buttons["Push route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Second route"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["2件表示"].waitForExistence(timeout: 10))
        let list = app.descendants(matching: .any).matching(identifier: "historyList").firstMatch
        XCTAssertTrue(list.staticTexts["SPA second"].waitForExistence(timeout: 5))
        app.webViews.buttons["Replace route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Replaced route"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3件表示"].waitForExistence(timeout: 10))
        XCTAssertTrue(list.staticTexts["SPA replaced"].waitForExistence(timeout: 5))
        app.buttons["backButton"].click()
        let address = app.textFields["addressField"]
        let atStart = expectation(for: NSPredicate(format: "value == %@", base + "/spa"), evaluatedWith: address)
        wait(for: [atStart], timeout: 10)
        XCTAssertTrue(app.staticTexts["3件表示"].exists)
        app.webViews.buttons["Sensitive route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Excluded route"].waitForExistence(timeout: 5))
        app.webViews.buttons["Rename route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Renamed route"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3件表示"].exists)
        XCTAssertFalse(list.staticTexts["Excluded route"].exists)
        app.webViews.buttons["Replace route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Replaced route"].waitForExistence(timeout: 5))
        XCTAssertTrue(list.staticTexts["SPA replaced"].waitForExistence(timeout: 5))
        app.buttons["clearHistoryButton"].click()
        app.buttons["confirmClearHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["0件表示"].waitForExistence(timeout: 10))
        app.webViews.buttons["Rename route"].click()
        XCTAssertTrue(app.webViews.staticTexts["Renamed route"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0件表示"].exists)
        attachWindowImage(app, name: "same-document-history-cleared", knownFrame: app.windows["browser"].frame)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testHistorySearchDeleteAndClearKeepBookmarksAndTheCurrentPage() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.textFields["bookmarkTitleField"].waitForExistence(timeout: 10))
        app.buttons["closeBookmarksButton"].click()
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["2件表示"].waitForExistence(timeout: 10))
        let search = app.textFields["historySearchField"]
        search.click()
        waitForInputIndicator(in: app)
        search.typeText("/one")
        waitForInputIndicator(in: app)
        search.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["1件表示"].waitForExistence(timeout: 10))
        let list = app.descendants(matching: .any).matching(identifier: "historyList").firstMatch
        let one = list.staticTexts["Fixture one"].firstMatch
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        one.click()
        attachWindowImage(app, name: "history-panel", knownFrame: app.windows["browser"].frame)
        app.buttons["openHistoryButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["2件表示"].waitForExistence(timeout: 10))
        let two = list.staticTexts["Fixture two"].firstMatch
        XCTAssertTrue(two.waitForExistence(timeout: 5))
        two.click()
        let remove = app.buttons["deleteHistoryButton"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        XCTAssertTrue(app.staticTexts["1件表示"].waitForExistence(timeout: 10))
        app.buttons["clearHistoryButton"].click()
        app.buttons["confirmClearHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["0件表示"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].exists)
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].exists)
        app.buttons["showBookmarksButton"].click()
        XCTAssertTrue(app.staticTexts["1件・上限1000件"].waitForExistence(timeout: 5))
        app.buttons["closeBookmarksButton"].click()
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testBookmarksCanBeRenamedSearchedReopenedAndRestored() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        app.typeKey("d", modifierFlags: .command)
        let title = app.textFields["bookmarkTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        title.click()
        waitForInputIndicator(in: app)
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Saved research page")
        app.buttons["saveBookmarkTitleButton"].click()
        XCTAssertTrue(app.staticTexts["Saved research page"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey("d", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["1件・上限1000件"].waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Saved research page")
        let search = app.textFields["bookmarkSearchField"]
        search.click()
        waitForInputIndicator(in: app)
        search.typeText("does-not-match")
        XCTAssertFalse(app.staticTexts["Saved research page"].exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        waitForInputIndicator(in: app)
        let row = app.staticTexts["Saved research page"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.click()
        attachWindowImage(app, name: "bookmarks-panel", knownFrame: app.windows["browser"].frame)
        app.buttons["openBookmarkButton"].click()
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].waitForExistence(timeout: 10))
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The bookmark panel must not prevent normal termination")
        app.launch()
        app.activate()
        app.buttons["showBookmarksButton"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].waitForExistence(timeout: 10))
        row.click()
        app.buttons["deleteBookmarkButton"].click()
        XCTAssertTrue(app.staticTexts["0件・上限1000件"].waitForExistence(timeout: 5))
        app.buttons["undoBookmarkDeletionButton"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["closeBookmarksButton"].click()
        XCTAssertFalse(app.textFields["bookmarkSearchField"].exists)
        app.terminate()
    }

    @MainActor
    func testPostPDFCannotBeAddedAsAReloadableBookmark() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/pdf-post-form", in: app)
        let button = app.webViews.buttons["Submit PDF fixture"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.staticTexts["webPDFNotice"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["ブックマーク"].click()
        XCTAssertFalse(app.menuItems["現在のページを追加"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["showHistoryButton"].click()
        XCTAssertTrue(app.staticTexts["1件表示"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "historyList").firstMatch.staticTexts["PDF POST form"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testWebPDFDisplaysAndFindsText() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launch()
        app.activate()
        let frame = app.windows["browser"].frame
        submit(base + "/pdf-cookie", in: app)
        let link = app.webViews.links["Protected PDF"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        link.click()
        XCTAssertTrue(app.staticTexts["webPDFNotice"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["synthetic.pdf"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["pageFindField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.typeText("nebula")
        waitForInputIndicator(in: app)
        find.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["見つかりました"].waitForExistence(timeout: 10))
        app.buttons["closeFindButton"].click()
        attachWindowImage(app, name: "web-pdf-displayed", knownFrame: frame)
        app.typeKey("+", modifierFlags: .command)
        app.typeKey("+", modifierFlags: .command)
        attachWindowImage(app, name: "web-pdf-zoomed", knownFrame: frame)
        app.windows["browser"].coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)).click()
        app.typeKey(.pageDown, modifierFlags: [])
        app.typeKey(.pageDown, modifierFlags: [])
        attachWindowImage(app, name: "web-pdf-scrolled", knownFrame: frame)
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.typeKey("a", modifierFlags: .command)
        find.typeText("Second PDF page")
        waitForInputIndicator(in: app)
        find.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["見つかりました"].waitForExistence(timeout: 10))
        app.buttons["closeFindButton"].click()
        attachWindowImage(app, name: "web-pdf-second-page", knownFrame: frame)
        app.typeKey("s", modifierFlags: .command)
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.click()
        XCTAssertTrue(app.staticTexts["保存しました"].waitForExistence(timeout: 15))
        let saved = try XCTUnwrap(CGPDFDocument(folder.appendingPathComponent("synthetic.pdf") as CFURL))
        XCTAssertEqual(saved.numberOfPages, 2)
        XCTAssertTrue(app.staticTexts["webPDFNotice"].exists)
        app.terminate()
    }

    @MainActor
    func testAddressNavigationFromLocalPDFReplacesTheDisplayedPage() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("replacement-synthetic.pdf")
        try writeSyntheticPDF(to: document)
        app.launch()
        app.activate()
        app.typeKey("o", modifierFlags: .command)
        let open = app.sheets.buttons["開く"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(document.path)
        app.typeKey(.return, modifierFlags: [])
        open.click()
        XCTAssertTrue(app.staticTexts["localPDFNotice"].waitForExistence(timeout: 10))
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["pageFindField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.typeText("nebula")
        waitForInputIndicator(in: app)
        find.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["見つかりました"].waitForExistence(timeout: 10))
        app.buttons["closeFindButton"].click()
        attachWindowImage(app, name: "pdf-before-web-navigation")
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["localPDFNotice"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/two")
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        attachWindowImage(app, name: "web-after-local-pdf-navigation")
        app.terminate()
    }

    @MainActor
    func testSelectedLocalPDFOpensWithoutReplacingTheCurrentPage() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launchEnvironment["LEVISTICA_SESSION_TEST_ID"] = UUID().uuidString
        let document = folder.appendingPathComponent("local-synthetic.pdf")
        try writeSyntheticPDF(to: document)
        let malformed = folder.appendingPathComponent("malformed.pdf")
        try Data("Not a PDF".utf8).write(to: malformed)
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("o", modifierFlags: .command)
        let open = app.sheets.buttons["開く"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(open.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(malformed.path)
        app.typeKey(.return, modifierFlags: [])
        open.click()
        XCTAssertTrue(app.staticTexts["このファイルをPDFとして開けませんでした。元のファイルを確認してください。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].exists)
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.buttons["閉じる"].click()
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(document.path)
        app.typeKey(.return, modifierFlags: [])
        let frame = app.windows["browser"].frame
        open.click()
        XCTAssertTrue(app.buttons["reloadButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["localPDFNotice"].exists)
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].exists)
        app.typeKey("f", modifierFlags: .command)
        let find = app.textFields["pageFindField"]
        XCTAssertTrue(find.waitForExistence(timeout: 5))
        waitForInputIndicator(in: app)
        find.typeText("nebula")
        waitForInputIndicator(in: app)
        find.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["見つかりました"].waitForExistence(timeout: 10))
        app.buttons["closeFindButton"].click()
        attachWindowImage(app, name: "local-pdf-displayed", knownFrame: frame)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["PDFを選び直す"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].exists)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["PDFを選び直す"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み0"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, "")
        app.buttons["PDFを選び直す"].click()
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(document.path)
        app.typeKey(.return, modifierFlags: [])
        open.click()
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み1"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testPDFResponseMarkedAsAttachmentIsSavedInsteadOfDisplayed() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        submit(base + "/attachment.pdf", in: app)
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.click()
        XCTAssertTrue(app.staticTexts["保存しました"].waitForExistence(timeout: 15))
        let saved = folder.appendingPathComponent("synthetic.pdf")
        let pdf = try XCTUnwrap(CGPDFDocument(saved as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].exists)
        app.terminate()
    }

    @MainActor
    func testPostPDFCannotBeSavedByReplayingTheSubmission() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/pdf-post-form", in: app)
        let submit = app.webViews.buttons["Submit PDF fixture"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        submit.click()
        XCTAssertTrue(app.staticTexts["webPDFNotice"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["File"].click()
        let save = app.menuItems["PDFを保存…"]
        XCTAssertTrue(save.exists)
        XCTAssertFalse(save.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    @MainActor
    private func writeSyntheticPDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for heading in ["Local synthetic PDF", "Local second PDF page"] {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (heading as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            ("Local searchable nebula marker" as NSString).draw(at: CGPoint(x: 72, y: 650), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    @MainActor
    func testDepartureConfirmationPreservesInputOnCancelAndAllowsExplicitReload() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.links["Second page"].waitForExistence(timeout: 10))
        submit(base + "/departure", in: app)
        let draft = app.webViews.textFields["Departure draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        submit(base + "/two", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.buttons["backButton"].click()
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("synthetic protected draft")
        waitForInputIndicator(in: app)
        XCTAssertTrue(app.images.matching(identifier: "入力操作あり").firstMatch.waitForExistence(timeout: 5))
        app.buttons["forwardButton"].click()
        XCTAssertTrue(app.sheets.buttons["ページに戻る"].waitForExistence(timeout: 5))
        app.sheets.buttons["ページに戻る"].click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        app.webViews.links["Same document"].click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        XCTAssertFalse(app.sheets.buttons["ページに戻る"].exists)
        app.buttons["backButton"].click()
        XCTAssertTrue(app.sheets.buttons["ページに戻る"].waitForExistence(timeout: 5))
        app.sheets.buttons["ページに戻る"].click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        app.buttons["reloadButton"].click()
        let keep = app.sheets.buttons["ページに戻る"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        attachWindowImage(app, name: "departure-confirmation")
        app.sheets.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        app.webViews.links["Leave draft"].click()
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        submit(base + "/two", in: app)
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        XCTAssertTrue((app.textFields["addressField"].value as? String)?.contains("/departure") == true)
        submit(base + "/departure#another", in: app)
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        app.buttons["backButton"].click()
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.click()
        XCTAssertEqual(draft.value as? String, "synthetic protected draft")
        app.buttons["reloadButton"].click()
        let leave = app.sheets.buttons["入力を破棄して移動"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5))
        leave.click()
        let cleared = expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: draft)
        wait(for: [cleared], timeout: 10)
        app.terminate()
    }

    @MainActor
    func testFormSubmissionAfterEditingIsNotTreatedAsAbandoningInput() throws {
        continueAfterFailure = false
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/departure", in: app)
        let draft = app.webViews.textFields["Submission draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("synthetic send")
        waitForInputIndicator(in: app)
        app.webViews.buttons["Send draft"].click()
        XCTAssertTrue(app.webViews.staticTexts["Submission received"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.sheets.buttons["ページに戻る"].exists)
        app.terminate()
    }

    @MainActor
    func testEditedTabRequiresDiscardAndCancelPreservesItsDraft() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/tab-state", in: app)
        let draft = app.webViews.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("synthetic draft to protect")
        waitForInputIndicator(in: app)
        XCTAssertTrue(app.images.matching(identifier: "入力操作あり").firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        let keep = try nativeDialogButton("タブに戻る", in: app)
        app.dialogs.firstMatch.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "synthetic draft to protect")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.typeKey("w", modifierFlags: .command)
        try nativeDialogButton("入力を破棄して閉じる", in: app).click()
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testProgrammaticInputCannotMarkATabOrAccessTheNativeHandler() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/input-guard", in: app)
        let programmatic = app.webViews.buttons["Programmatic input"]
        XCTAssertTrue(programmatic.waitForExistence(timeout: 10))
        programmatic.click()
        XCTAssertTrue(app.webViews.staticTexts["Page native handler absent"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.images.matching(identifier: "入力操作あり").firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testQuitConfirmationIncludesEditedFramesAndKeepsDraftsOnReturn() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/tab-state", in: app)
        let first = app.webViews.textFields["Draft"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        waitForInputIndicator(in: app)
        first.typeText("synthetic first draft")
        waitForInputIndicator(in: app)
        app.typeKey("t", modifierFlags: .command)
        submit(base + "/input-guard", in: app)
        let frame = app.webViews.textFields["Frame draft"]
        XCTAssertTrue(frame.waitForExistence(timeout: 10))
        frame.click()
        waitForInputIndicator(in: app)
        frame.typeText("synthetic frame draft")
        waitForInputIndicator(in: app)
        let markers = app.images.matching(identifier: "入力操作あり")
        XCTAssertTrue(markers.element(boundBy: 1).waitForExistence(timeout: 5))
        let fixtureFrame = app.windows["browser"].frame
        app.typeKey("q", modifierFlags: .command)
        let keep = try nativeDialogButton("アプリに戻る", in: app)
        XCTAssertTrue(app.dialogs.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "2件", "2件")).firstMatch.exists)
        attachWindowImage(app, name: "edited-input-quit-confirmation", knownFrame: fixtureFrame)
        app.dialogs.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5))
        XCTAssertEqual(frame.value as? String, "synthetic frame draft")
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.value as? String, "synthetic first draft")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.typeKey("q", modifierFlags: .command)
        try nativeDialogButton("入力を破棄して終了", in: app).click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testRelatedPageKeepsIndependentInputAndItsScriptCloseStillCompletes() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/related", in: app)
        XCTAssertTrue(app.webViews.buttons["Open related page"].waitForExistence(timeout: 10))
        app.webViews.buttons["Open related page"].click()
        let child = app.webViews.textFields["Child draft"]
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        child.click()
        waitForInputIndicator(in: app)
        child.typeText("synthetic related draft")
        waitForInputIndicator(in: app)
        XCTAssertTrue(app.images.matching(identifier: "入力操作あり").firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        try nativeDialogButton("タブに戻る", in: app).click()
        XCTAssertEqual(child.value as? String, "synthetic related draft")
        app.webViews.buttons["Send result and close"].click()
        XCTAssertTrue(app.webViews.staticTexts["Related page completed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        XCTAssertFalse(app.images.matching(identifier: "入力操作あり").firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み0"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testSiteDialogsReturnAlertConfirmAndPromptResults() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/dialogs", in: app)
        let alertButton = app.webViews.buttons["Site alert"]
        XCTAssertTrue(alertButton.waitForExistence(timeout: 10))
        let fixtureFrame = app.windows["browser"].frame
        alertButton.click()
        let ok = try siteDialogButton("OK", in: app)
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Synthetic site notice", "Synthetic site notice")).firstMatch.exists)
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", base, base)).firstMatch.exists)
        attachWindowImage(app, name: "site-alert-origin", knownFrame: fixtureFrame)
        ok.click()
        XCTAssertTrue(app.webViews.staticTexts["Alert returned"].waitForExistence(timeout: 5))
        app.webViews.buttons["Site confirm"].click()
        try siteDialogButton("キャンセル", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Confirm: false"].waitForExistence(timeout: 5))
        app.webViews.buttons["Site confirm"].click()
        try siteDialogButton("OK", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Confirm: true"].waitForExistence(timeout: 5))
        app.webViews.buttons["Site prompt"].click()
        _ = try siteDialogButton("OK", in: app)
        // NSAlert focuses and selects the prompt's default text on presentation.
        let promptSheet = app.sheets.firstMatch
        promptSheet.typeKey("a", modifierFlags: .command)
        promptSheet.typeText("synthetic reply")
        // Let the OS input-source HUD fade without querying the paused WebContent tree.
        Thread.sleep(forTimeInterval: 2.5)
        attachWindowImage(app, name: "site-prompt-input", knownFrame: fixtureFrame)
        try siteDialogButton("OK", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt: synthetic reply"].waitForExistence(timeout: 5))
        app.webViews.buttons["Site prompt"].click()
        try siteDialogButton("キャンセル", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Prompt: cancelled"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testStoppingSiteDialogsAndReloadingResetsTheChoice() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/dialogs", in: app)
        let repeated = app.webViews.buttons["Repeated alerts"]
        XCTAssertTrue(repeated.waitForExistence(timeout: 10))
        repeated.click()
        try siteDialogButton("このページのダイアログを停止", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Dialogs completed: 8"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["siteDialogNotice"].exists)
        app.buttons["reloadButton"].click()
        XCTAssertTrue(app.webViews.staticTexts["Waiting for dialog"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.buttons["Frame confirm"].waitForExistence(timeout: 10))
        app.webViews.buttons["Frame confirm"].click()
        _ = try siteDialogButton("キャンセル", in: app)
        let frameOrigin = base.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        XCTAssertTrue(app.sheets.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", frameOrigin, frameOrigin)).firstMatch.exists)
        try siteDialogButton("キャンセル", in: app).click()
        XCTAssertTrue(app.webViews.staticTexts["Frame: false"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    func testQuitClosesAPendingSiteDialog() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/dialogs", in: app)
        XCTAssertTrue(app.webViews.buttons["Site confirm"].waitForExistence(timeout: 10))
        app.webViews.buttons["Site confirm"].click()
        _ = try siteDialogButton("キャンセル", in: app)
        app.sheets.firstMatch.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testLongSiteMessageKeepsTheConfirmationButtonReachable() throws {
        continueAfterFailure = false
        executionTimeAllowance = 120
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/dialogs", in: app)
        XCTAssertTrue(app.webViews.buttons["Long site alert"].waitForExistence(timeout: 10))
        let fixtureFrame = app.windows["browser"].frame
        app.webViews.buttons["Long site alert"].click()
        let ok = try siteDialogButton("OK", in: app)
        let reachable = ok.isHittable
        attachWindowImage(app, name: "site-long-message", knownFrame: fixtureFrame)
        let message = app.sheets.scrollViews.firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        message.scroll(byDeltaX: 0, deltaY: -3000)
        attachWindowImage(app, name: "site-long-message-scrolled", knownFrame: fixtureFrame)
        message.scroll(byDeltaX: 0, deltaY: 3000)
        app.sheets.firstMatch.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.webViews.staticTexts["Long alert returned"].waitForExistence(timeout: 5))
        XCTAssertTrue(reachable, "A site message must not push its confirmation button off-screen.")
        app.terminate()
    }

    @MainActor
    private func siteDialogButton(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        let button = app.sheets.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        return button
    }

    @MainActor
    func testExternalURLReopensTheWindowAndKeepsTheOriginalDraft() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/tab-state", in: app)
        let draft = app.webViews.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("keep across native reopen")
        let window = app.windows["browser"]
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.state, .notRunning)
        try deliverNativeURLs([XCTUnwrap(URL(string: base + "/two"))])
        app.activate()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].exists)
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.textFields["Draft"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.textFields["Draft"].value as? String, "keep across native reopen")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.terminate()
    }

    @MainActor
    func testNativeReopenWithoutURLRestoresTheExistingWindow() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        let window = app.windows["browser"]
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5))
        XCTAssertNotEqual(app.state, .notRunning)
        try deliverNativeURLs([])
        app.activate()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.terminate()
    }

    @MainActor
    private func deliverNativeURLs(_ urls: [URL]) throws {
        // This helper must only address the already-running EPHEMERAL test app.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let application = root.appendingPathComponent(".local/DerivedData/Build/Products/Debug/Levistica.app")
        _ = try XCTUnwrap(NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL == application.standardizedFileURL && !$0.isTerminated
        }, "The isolated application must already be running; never cold-launch from the sandboxed runner.")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.environment = ["LEVISTICA_EPHEMERAL": "1"]
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        let delivered = expectation(description: "Launch Services delivered the request to this checkout")
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { application, error in
            XCTAssertNotNil(application)
            XCTAssertNil(error)
            delivered.fulfill()
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: completion)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration, completionHandler: completion)
        }
        wait(for: [delivered], timeout: 15)
    }

    @MainActor
    func testQuittingCancelsAnUnfinishedTransfer() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launch()
        app.activate()
        submit(base + "/files", in: app)
        let link = app.webViews.links["Slow download"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.click()
        XCTAssertTrue(app.staticTexts["ダウンロード中"].waitForExistence(timeout: 10))
        pageMenu("このタブを休眠…", in: app)
        XCTAssertTrue(app.staticTexts["ダウンロード中のタブは休眠しません。完了するか、転送を取り消してください。"].waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        let quit = try nativeDialogButton("転送を取り消して終了", in: app)
        quit.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fixture-download.txt").path))
    }

    @MainActor
    func testCancellingTransferPreservesExistingFileAndQuitCanBeCancelled() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("fixture-download.txt")
        try Data("keep the original".utf8).write(to: target)
        app.launch()
        app.activate()
        submit(base + "/files", in: app)
        let link = app.webViews.links["Slow download"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.click()
        let replaceEnglish = app.buttons["Replace"].firstMatch
        let replaceJapanese = app.buttons["置き換える"].firstMatch
        XCTAssertTrue(replaceEnglish.waitForExistence(timeout: 3) || replaceJapanese.waitForExistence(timeout: 3), app.debugDescription)
        let replacements = [app.dialogs.buttons["Replace"].firstMatch, app.sheets.buttons["Replace"].firstMatch,
                            app.windows.buttons["Replace"].firstMatch, app.dialogs.buttons["置き換える"].firstMatch,
                            app.sheets.buttons["置き換える"].firstMatch, app.windows.buttons["置き換える"].firstMatch]
        let replace = try XCTUnwrap(replacements.first(where: { $0.exists }), app.debugDescription)
        replace.click()
        XCTAssertTrue(app.staticTexts["ダウンロード中"].waitForExistence(timeout: 10), app.debugDescription)
        attachWindowImage(app, name: "active-download")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep the original")
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["ダウンロード中です。転送を取り消すか、完了してからタブを閉じてください。"].waitForExistence(timeout: 5))
        app.typeKey("q", modifierFlags: .command)
        let stay = try nativeDialogButton("アプリに戻る", in: app)
        stay.click()
        XCTAssertEqual(app.state, .runningForeground)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "cancelDownload-")).firstMatch.click()
        XCTAssertTrue(app.staticTexts["取り消しました"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep the original")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    }

    @MainActor
    func testFailedTransferDoesNotCreateACompletedFile() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launch()
        app.activate()
        submit(base + "/files", in: app)
        let link = app.webViews.links["Failed download"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.click()
        XCTAssertTrue(app.staticTexts["ダウンロードに失敗しました。元のリンクから試してください。"].waitForExistence(timeout: 15))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("fixture-download.txt").path))
        app.terminate()
    }

    @MainActor
    func testDownloadingDoesNotEnableReloadOfAPostResponse() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let (app, folder) = try fileTestApplication()
        defer { try? FileManager.default.removeItem(at: folder) }
        app.launch()
        app.activate()
        submit(base + "/post-form", in: app)
        let submitButton = app.webViews.buttons["Submit fixture"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 10))
        submitButton.click()
        let link = app.webViews.links["Download fixture"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        XCTAssertTrue(app.windows.buttons["保存"].firstMatch.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["取り消しました"].waitForExistence(timeout: 10))
        app.buttons["reloadButton"].click()
        XCTAssertTrue(app.staticTexts["送信内容の重複を避けるため、このページは自動で再送しません。URLを入力して開き直してください。"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @MainActor
    private func nativeDialogButton(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5))
        let candidates = [app.dialogs.buttons[title].firstMatch, app.sheets.buttons[title].firstMatch,
                          app.windows.buttons[title].firstMatch]
        return try XCTUnwrap(candidates.first(where: { $0.exists }), app.debugDescription)
    }

    @MainActor
    private func fileTestApplication() throws -> (XCUIApplication, URL) {
        let id = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LevisticaFiles-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_FILE_TEST_ID"] = id.uuidString
        app.launchEnvironment["LEVISTICA_FILE_TEST_DIRECTORY"] = folder.path
        return (app, folder)
    }

    @MainActor
    func testDownloadAndSelectOnlyTheSyntheticUpload() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let id = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LevisticaFiles-" + id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let upload = folder.appendingPathComponent("synthetic-upload.txt")
        try Data("levistica synthetic upload\n".utf8).write(to: upload)
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launchEnvironment["LEVISTICA_FILE_TEST_ID"] = id.uuidString
        app.launchEnvironment["LEVISTICA_FILE_TEST_DIRECTORY"] = folder.path
        app.launch()
        app.activate()
        submit(base + "/files", in: app)
        let link = app.webViews.links["Download fixture"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.click()
        let save = app.windows.buttons["保存"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), app.windows.debugDescription)
        save.click()
        XCTAssertTrue(app.staticTexts["保存しました"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["errorMessage"].exists)
        XCTAssertEqual(app.textFields["addressField"].value as? String, base + "/files")
        let downloaded = folder.appendingPathComponent("fixture-download.txt")
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "levistica synthetic download\n")
        XCTAssertNotNil(try downloaded.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        let input = app.webViews.buttons["Attachment"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        let choose = app.sheets.buttons["選択"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(upload.path)
        app.typeKey(.return, modifierFlags: [])
        choose.click()
        XCTAssertTrue(app.webViews.staticTexts["synthetic-upload.txt"].waitForExistence(timeout: 10))
        app.webViews.buttons["Upload synthetic fixture"].click()
        XCTAssertTrue(app.webViews.staticTexts["Synthetic upload received"].waitForExistence(timeout: 10))
        attachWindowImage(app, name: "download-and-upload-complete")
        app.terminate()
    }

    @MainActor
    func testOneUserActionCannotOpenTwentyRelatedTabs() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/popup-burst", in: app)
        let button = app.webViews.buttons["Open twenty related pages"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.webViews.staticTexts["Burst child"].waitForExistence(timeout: 10))
        app.typeKey("[", modifierFlags: [.command, .shift])
        // The newest child is inserted immediately after its opener.
        XCTAssertTrue(app.webViews.buttons["Open twenty related pages"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 5))
        let summary = app.staticTexts["tabLoadSummary"]
        let text = (summary.value as? String) ?? summary.label
        let count = try XCTUnwrap(Int(text.prefix(while: { $0.isNumber })))
        XCTAssertGreaterThan(count, 1)
        XCTAssertLessThanOrEqual(count, 6)
        app.terminate()
    }

    @MainActor
    func testRelatedPageSharesCookieReturnsMessageAndCloses() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/related", in: app)
        let draft = app.webViews.textFields["Draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        waitForInputIndicator(in: app)
        draft.click()
        waitForInputIndicator(in: app)
        draft.typeText("keep this synthetic draft")
        app.webViews.buttons["Open related page"].click()
        XCTAssertTrue(app.webViews.staticTexts["Shared fixture cookie"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].exists)
        XCTAssertTrue(app.staticTexts["pageOpenerOrigin"].exists)
        app.webViews.buttons["Send result and close"].click()
        XCTAssertTrue(app.webViews.staticTexts["Related page completed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.textFields["Draft"].value as? String, "keep this synthetic draft")
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.webViews.buttons["Open blank related page"].click()
        XCTAssertTrue(app.webViews.staticTexts["Shared fixture cookie"].waitForExistence(timeout: 10))
        app.webViews.buttons["Send result and close"].click()
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].waitForExistence(timeout: 10))
        app.terminate()
    }

    @MainActor
    func testCommandClickKeepsTheOpenerAndTargetBlankOpensAnotherTab() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/related", in: app)
        let link = app.webViews.links["Ordinary link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCUIElement.perform(withKeyModifiers: .command) { link.click() }
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.buttons["Open related page"].exists)
        app.typeKey("]", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        app.typeKey("w", modifierFlags: .command)
        let blankLink = app.webViews.links["New target link"]
        XCTAssertTrue(blankLink.waitForExistence(timeout: 10))
        blankLink.click()
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture two"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2タブ・読み込み済み2"].exists)
        app.typeKey("w", modifierFlags: .command)
        app.webViews.links["Blocked new target"].click()
        XCTAssertTrue(app.staticTexts["errorMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.terminate()
    }

    @MainActor
    func testRelatedPostIsDeliveredOnceAndNotReplayedOnReopen() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/related", in: app)
        let button = app.webViews.buttons["Submit in related page"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.webViews.staticTexts["Popup POST received"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["POST deliveries: 1"].exists)
        app.typeKey("w", modifierFlags: .command)
        app.typeKey("t", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["送信後のページです。URLを確認してから開いてください。"].exists)
        XCTAssertEqual(app.webViews.count, 0)
        app.terminate()
    }

    @MainActor
    func testUnsolicitedPopupIsBlocked() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
        let app = XCUIApplication()
        app.launchEnvironment["LEVISTICA_EPHEMERAL"] = "1"
        app.launch()
        app.activate()
        submit(base + "/automatic-popup", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Automatic popup blocked"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["1タブ・読み込み済み1"].exists)
        app.terminate()
    }

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
        app.buttons["showBookmarksButton"].click()
        XCTAssertTrue(app.textFields["bookmarkSearchField"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.textFields["bookmarkSearchField"].exists)
        app.buttons["closeBookmarksButton"].click()
        XCTAssertFalse(app.textFields["bookmarkSearchField"].exists)
        XCTAssertGreaterThan(app.webViews.firstMatch.frame.width, beforeFrame.width + 200)
        attachWindowImage(app, name: "fullscreen-after-bookmarks-closed")
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
        app.buttons["showBookmarksButton"].click()
        XCTAssertTrue(app.textFields["bookmarkSearchField"].waitForExistence(timeout: 5))
        app.buttons["closeBookmarksButton"].click()
        XCTAssertEqual(draft.value as? String, "keep this draft")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.typeKey("t", modifierFlags: .command)
        XCTAssertEqual(app.webViews.count, 0)
        submit(base + "/one", in: app)
        XCTAssertTrue(app.webViews.staticTexts["Levistica fixture one"].waitForExistence(timeout: 10))
        app.typeKey("[", modifierFlags: [.command, .shift])
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertEqual(draft.value as? String, "keep this draft")
        XCTAssertTrue(app.webViews.staticTexts["Document loads: 1"].exists)
        app.typeKey("w", modifierFlags: .command)
        try nativeDialogButton("入力を破棄して閉じる", in: app).click()
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
    private func attachWindowImage(_ app: XCUIApplication, name: String, knownFrame: CGRect? = nil) {
        // macOS application screenshots may include other applications. Crop to this
        // fixture window before retaining any image in the test result.
        let image = knownFrame == nil ? app.screenshot().image : XCUIScreen.main.screenshot().image
        let frame = knownFrame ?? app.windows.firstMatch.frame
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
