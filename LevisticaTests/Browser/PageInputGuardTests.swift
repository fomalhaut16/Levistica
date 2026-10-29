import Testing
import WebKit
import JavaScriptCore
@testable import Levistica

// WebKit suites share a process and its services. Serialize the suites
// together, including async suspension points; unrelated pure tests stay parallel.
@Suite(.serialized)
struct WebKitIntegrationTests {}

extension WebKitIntegrationTests {
@MainActor
struct PageInputGuardTests {
    private func httpFixtureURL(environmentKey: String = "LEVISTICA_FIXTURE_URL", path: String) throws -> URL {
        let raw = try #require(ProcessInfo.processInfo.environment[environmentKey], "Run script/test.sh for loopback fixtures.")
        let base = try #require(URL(string: raw))
        try #require(base.scheme == "http" && base.host == "127.0.0.1" && base.port != nil
                     && base.user == nil && base.password == nil && base.query == nil && base.fragment == nil
                     && (base.path.isEmpty || base.path == "/"))
        return base.appendingPathComponent(path)
    }

    @Test(arguments: ["download", "redirect-download"])
    func actualHTTPDownloadPreservesTheDisplayedDocumentAndIdentity(path: String) async throws {
        let destination = try httpFixtureURL(path: path)
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.onDownload = nil; runtime.stop() }
        let pageURL = try #require(URL(string: "https://www.google.com/"))
        runtime.webView.loadSimulatedRequest(URLRequest(url: pageURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>HTTP download fixture</title>")
        let pageDeadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "HTTP download fixture", ContinuousClock.now < pageDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "HTTP download fixture")
        let originalAgent = runtime.webView.customUserAgent ?? ""
        var receivedDownload = false
        var agentAtDownload: String?
        var locationAtDownload: URL?
        runtime.onDownload = { [weak runtime] download in
            agentAtDownload = runtime?.webView.customUserAgent ?? ""
            locationAtDownload = runtime?.url
            receivedDownload = true
            download.cancel { _ in }
        }
        runtime.load(destination)
        let downloadDeadline = ContinuousClock.now + .seconds(15)
        while !receivedDownload, ContinuousClock.now < downloadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(receivedDownload)
        #expect(runtime.webView.title == "HTTP download fixture")
        #expect(runtime.url == pageURL)
        #expect(locationAtDownload == pageURL)
        #expect(runtime.canRetry)
        #expect(runtime.failure == nil)
        #expect(agentAtDownload == originalAgent)
    }

    @Test func actualRedirectRecordsAndReloadsTheFinalDocument() async throws {
        let start = try httpFixtureURL(path: "redirect-two")
        let final = try httpFixtureURL(path: "two")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.onVisit = nil; runtime.stop() }
        var visits: [URL] = []
        runtime.onVisit = { url, _, _ in visits.append(url) }
        runtime.load(start)
        let deadline = ContinuousClock.now + .seconds(10)
        while visits.isEmpty || runtime.webView.title != "Fixture two" || runtime.webView.isLoading,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(visits == [final])
        #expect(runtime.webView.title == "Fixture two")
        #expect(runtime.url == final)
        #expect(runtime.canRetry)
        runtime.reload()
        let reloadDeadline = ContinuousClock.now + .seconds(10)
        while visits.count < 2 || runtime.webView.title != "Fixture two" || runtime.webView.isLoading,
              ContinuousClock.now < reloadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(visits == [final, final])
        #expect(runtime.url == final)
    }

    @Test func actualRedirectFailureKeepsTheDocumentAndFinalRetryDestination() async throws {
        let page = try httpFixtureURL(path: "one")
        let start = try httpFixtureURL(path: "redirect-failure")
        let final = try httpFixtureURL(environmentKey: "LEVISTICA_FAILURE_FIXTURE_URL", path: "failure")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        runtime.load(page)
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Fixture one", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Fixture one")
        runtime.load(start)
        let failureDeadline = ContinuousClock.now + .seconds(15)
        while runtime.failure == nil, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.failure != nil)
        #expect(runtime.webView.title == "Fixture one")
        #expect(runtime.url == final)
        #expect(runtime.canRetry)
    }

    @Test(arguments: [303, 307])
    func actualPOSTRedirectDoesNotReplayTheSubmission(status: Int) async throws {
        let start = try httpFixtureURL(path: "redirect-\(status)")
        let final = try httpFixtureURL(path: status == 303 ? "two" : "redirect-post-target")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        var request = URLRequest(url: start)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic=1".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        runtime.load(request)
        let title = status == 303 ? "Fixture two" : "Redirect POST fixture"
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != title || runtime.webView.isLoading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == title)
        #expect(runtime.url == final)
        #expect(runtime.canRetry == (status == 303))
        let revision = runtime.documentRevision
        runtime.reload()
        if status == 303 {
            let reloadDeadline = ContinuousClock.now + .seconds(10)
            while runtime.documentRevision == revision || runtime.webView.isLoading, ContinuousClock.now < reloadDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(runtime.documentRevision > revision)
            #expect(runtime.failure == nil)
        } else {
            #expect(runtime.failure != nil)
            runtime.retry()
            #expect(runtime.documentRevision == revision)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: httpFixtureURL(path: "redirect-post-count"))
        let counts = try #require(JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(counts["post\(status)"] == 1)
    }

    @Test func actualConnectionFailureKeepsTheDocumentAndRetryDestination() async throws {
        let page = try httpFixtureURL(path: "one")
        let failure = try httpFixtureURL(environmentKey: "LEVISTICA_FAILURE_FIXTURE_URL", path: "failure")
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        runtime.load(page)
        let pageDeadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Fixture one", ContinuousClock.now < pageDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Fixture one")
        runtime.load(failure)
        let failureDeadline = ContinuousClock.now + .seconds(15)
        while runtime.failure == nil, ContinuousClock.now < failureDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.failure != nil)
        #expect(runtime.webView.title == "Fixture one")
        #expect(runtime.url == failure)
        #expect(runtime.canRetry)
    }

    @Test(arguments: [false, true])
    func stoppingPreservesIdentityCapturedAtCommit(googleIdentity: Bool) async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        let initialURL = try #require(URL(string: googleIdentity ? "https://example.org/" : "https://www.google.com/"))
        let finalURL = try #require(URL(string: googleIdentity ? "https://www.google.com/" : "https://example.org/"))
        runtime.webView.loadSimulatedRequest(URLRequest(url: initialURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Commit identity fixture</title>")
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Commit identity fixture", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Commit identity fixture")
        // Model the delegate's final-response selection and commit separately.
        // loadSimulatedRequest itself does not reproduce a network redirect.
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: finalURL)
        runtime.webView(runtime.webView, didCommit: nil)
        let selectedAgent = runtime.webView.customUserAgent ?? ""
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: initialURL)
        runtime.stop()
        #expect((runtime.webView.customUserAgent ?? "") == selectedAgent)
    }

    @Test(arguments: ["https://www.google.com/", "https://example.org/"], ["stop", "failure", "cancel"])
    func interruptedNavigationKeepsTheDisplayedDocumentIdentity(address: String, interruption: String) async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        let pageURL = try #require(URL(string: address))
        runtime.webView.loadSimulatedRequest(URLRequest(url: pageURL), responseHTML:
            "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>Interruption fixture</title>")
        let deadline = ContinuousClock.now + .seconds(10)
        while runtime.webView.title != "Interruption fixture", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(runtime.webView.title == "Interruption fixture")
        func documentAgent() async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                runtime.webView.evaluateJavaScript("navigator.userAgent") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
        }
        let originalAgent = try await documentAgent()
        // Model the accepted provisional destination before a new document commits.
        // Its identity differs from the still-displayed, fully loaded fixture.
        let pendingURL = try #require(URL(string: address.contains("google") ? "https://example.org/" : "https://www.google.com/"))
        runtime.webView.customUserAgent = NavigationPolicy.userAgent(for: pendingURL)
        if interruption == "stop" {
            runtime.stop()
        } else {
            runtime.webView(runtime.webView, didFailProvisionalNavigation: nil,
                            withError: URLError(interruption == "cancel" ? .cancelled : .cannotConnectToHost))
        }
        #expect(runtime.webView.title == "Interruption fixture")
        #expect(try await documentAgent() == originalAgent)
        if interruption == "failure" { #expect(runtime.failure != nil) }
    }

    @Test func simulatedMainNavigationsResetGoogleIdentityWithoutNetworkAccess() async throws {
        let runtime = PageRuntime(dataStore: .nonPersistent())
        defer { runtime.stop() }
        for (index, address) in ["https://www.google.com/", "https://example.org/", "https://www.google.co.jp/",
                                 "https://accounts.google.com/"].enumerated() {
            let destination = try #require(URL(string: address))
            let title = "Identity fixture \(index)"
            runtime.webView.loadSimulatedRequest(URLRequest(url: destination), responseHTML:
                "<html><head><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\"><title>\(title)</title></head><body>Fixture</body></html>")
            let deadline = ContinuousClock.now + .seconds(10)
            while (runtime.webView.isLoading || runtime.webView.title != title), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.webView.title == title)
            #expect(runtime.webView.url == destination)
            if let expected = NavigationPolicy.userAgent(for: destination) {
                #expect(runtime.webView.customUserAgent == expected)
            } else {
                // WebKit normalizes a cleared custom agent to an empty string.
                #expect(runtime.webView.customUserAgent?.isEmpty ?? true)
            }
            let agent: String = try await withCheckedThrowingContinuation { continuation in
                runtime.webView.evaluateJavaScript("navigator.userAgent") { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
            if let expected = NavigationPolicy.userAgent(for: destination) {
                #expect(agent == expected)
            } else {
                #expect(agent.contains(WebKitBrowserIdentity.applicationName))
            }
        }
    }

    @Test func inheritedConfigurationPreservesScriptsWithoutSharingInputObservers() {
        let store = WKWebsiteDataStore.nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let marker = "globalThis.levisticaSyntheticMarker = true;"
        configuration.userContentController.addUserScript(WKUserScript(source: marker, injectionTime: .atDocumentStart,
                                                                       forMainFrameOnly: true))
        let parent = PageRuntime(configuration: configuration)
        let child = PageRuntime(configuration: parent.webView.configuration, permitsInitialBlankPage: true)
        let parentController = parent.webView.configuration.userContentController
        let childController = child.webView.configuration.userContentController
        #expect(parent.inputGuard !== child.inputGuard)
        #expect(parentController !== childController)
        #expect(child.webView.configuration.websiteDataStore === store)
        #expect(child.webView.configuration.applicationNameForUserAgent == parent.webView.configuration.applicationNameForUserAgent)
        #expect(childController.userScripts.contains { $0.source == marker })
        #expect(childController.userScripts.count == parentController.userScripts.count)
    }

    @Test func inputObserverDoesNotRetainItsWebView() {
        weak var view: WKWebView?
        weak var observer: PageInputGuard?
        autoreleasepool {
            let runtime = PageRuntime(dataStore: .nonPersistent())
            view = runtime.webView
            observer = runtime.inputGuard
        }
        #expect(view == nil)
        #expect(observer == nil)
    }

    @Test func endingTheRuntimeReleasesItsInputController() async throws {
        weak var controller: WKUserContentController?
        autoreleasepool {
            let runtime = PageRuntime(dataStore: .nonPersistent())
            controller = runtime.webView.configuration.userContentController
            #expect(controller != nil)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while controller != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller == nil)
    }
}
}

// These tests exercise the shipped script's event filtering, not a real IME.
@MainActor
struct PageIMECompatibilityTests {
    private func context() throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        const handlers = {};
        const window = { addEventListener(type, handler) {
            (handlers[type] ||= []).push(handler);
        }};
        function press(type, options = {}) {
            const event = Object.assign({isTrusted: true, key: 'Enter', code: 'Enter',
                location: 0, keyCode: 13, isComposing: false,
                stopped: false, cancelled: false,
                stopImmediatePropagation() { this.stopped = true; },
                preventDefault() { this.cancelled = true; }}, options);
            for (const handler of handlers[type] || []) {
                handler(event);
                if (event.stopped) break;
            }
            if (event.cancelled) throw new Error('Default editing must remain enabled');
            return event.stopped;
        }
        """)
        context.evaluateScript(PageIMECompatibility.source)
        try #require(context.exception == nil)
        return context
    }

    @Test func confirmationIsFilteredButTheFollowingSendIsPreserved() throws {
        let js = try context()
        #expect(js.evaluateScript("press('keydown', {keyCode:229})")?.toBool() == true)
        #expect(js.evaluateScript("press('keypress')")?.toBool() == true)
        #expect(js.evaluateScript("press('keyup')")?.toBool() == true)
        #expect(js.evaluateScript("press('keydown')")?.toBool() == false)
        #expect(js.evaluateScript("press('keypress')")?.toBool() == false)
        #expect(js.evaluateScript("press('keyup')")?.toBool() == false)
        #expect(js.exception == nil)
    }

    @Test(arguments: ["{isTrusted:false,keyCode:229}",
                      "{isComposing:true,keyCode:229}",
                      "{key:'a',keyCode:229}", "{shiftKey:true}"])
    func unrelatedEventsArePreserved(options: String) throws {
        let js = try context()
        #expect(js.evaluateScript("press('keydown', \(options))")?.toBool() == false)
        #expect(js.exception == nil)
    }

    @Test func newOrdinaryPressClearsAnUnmatchedConfirmation() throws {
        let js = try context()
        #expect(js.evaluateScript("press('keydown', {keyCode:229})")?.toBool() == true)
        #expect(js.evaluateScript("press('keydown')")?.toBool() == false)
        #expect(js.evaluateScript("press('keyup')")?.toBool() == false)
    }

    @Test func blurClearsAnUnmatchedConfirmation() throws {
        let js = try context()
        #expect(js.evaluateScript("press('keydown', {keyCode:229})")?.toBool() == true)
        js.evaluateScript("press('blur')")
        #expect(js.evaluateScript("press('keyup')")?.toBool() == false)
    }

    @Test func numpadEnterIsMatchedIndependently() throws {
        let js = try context()
        #expect(js.evaluateScript("press('keydown', {keyCode:229,code:'NumpadEnter'})")?.toBool() == true)
        #expect(js.evaluateScript("press('keyup')")?.toBool() == false)
        #expect(js.evaluateScript("press('keyup', {code:'NumpadEnter'})")?.toBool() == true)
        #expect(js.evaluateScript("press('keydown', {code:'NumpadEnter'})")?.toBool() == false)
    }
}

extension WebKitIntegrationTests {
    @MainActor
    struct PageIMEInstallationTests {
        @Test func configurationInheritanceDoesNotDuplicateTheAllFrameScript() {
            let controller = WKUserContentController()
            PageIMECompatibility.install(in: controller)
            PageIMECompatibility.install(in: controller)
            #expect(controller.userScripts.count == 1)
            #expect(controller.userScripts.first?.injectionTime == .atDocumentStart)
            #expect(controller.userScripts.first?.isForMainFrameOnly == false)
        }
    }
}

extension WebKitIntegrationTests {
    @MainActor
    struct PageLoginNavigationTests {
        private func preparedRuntime() async throws -> PageRuntime {
            let base = try #require(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
            let address = try #require(URL(string: base + "/login-flow"))
            let runtime = PageRuntime(dataStore: .nonPersistent())
            runtime.load(address)
            let deadline = ContinuousClock.now + .seconds(10)
            while runtime.webView.title != "Login flow fixture", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.webView.title == "Login flow fixture")
            // Set up edited-input state through the app-owned isolated world.
            // This models the native guard boundary; it is not a trusted-input test.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runtime.webView.evaluateJavaScript(
                    "window.webkit.messageHandlers.levisticaInputActivity.postMessage({frame: 'synthetic-frame', revision: 1, pending: true}); true",
                    in: nil, in: .world(name: "LevisticaInputActivity")) { result in
                        continuation.resume(with: result.map { _ in () })
                    }
            }
            let inputDeadline = ContinuousClock.now + .seconds(3)
            while !runtime.inputGuard.hasEditedInput, ContinuousClock.now < inputDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.inputGuard.hasEditedInput)
            return runtime
        }

        @Test func successfulScriptLoginCanNavigateAfterInput() async throws {
            let runtime = try await preparedRuntime()
            defer { runtime.stop() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                runtime.webView.evaluateJavaScript("document.getElementById('login').requestSubmit(); true") { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while runtime.webView.title != "Login flow completed", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(runtime.webView.title == "Login flow completed")
            #expect(runtime.url?.path == "/login-flow-done")
            #expect(runtime.inputGuard.hasEditedInput == false)
        }

        @Test func browserLoadIsCancelledSafelyWhenConfirmationCannotBeShown() async throws {
            let runtime = try await preparedRuntime()
            defer { runtime.stop() }
            let original = runtime.url
            let destination = try #require(original?.deletingLastPathComponent().appendingPathComponent("two"))
            runtime.load(destination)
            let deadline = ContinuousClock.now + .seconds(3)
            while runtime.dialogs.notice == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(runtime.url == original)
            #expect(runtime.webView.title == "Login flow fixture")
            #expect(runtime.dialogs.notice != nil)
            #expect(runtime.inputGuard.hasEditedInput)
        }
    }
}

extension WebKitIntegrationTests {
    @MainActor
    struct ManagedEditorIdentityTests {
        @Test func actualWebKitIdentitySelectsTheCorrespondingCommitPath() async throws {
            let base = try #require(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
            let address = try #require(URL(string: base + "/ime-rich-check"))
            let runtime = PageRuntime(dataStore: .nonPersistent())
            defer { runtime.stop() }
            runtime.load(address)
            let deadline = ContinuousClock.now + .seconds(10)
            while runtime.webView.title != "Rich editor IME check", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.webView.title == "Rich editor IME check")
            // Replay the known commit sequence with generated text. The prior
            // manual fixture is the real-IME evidence; these events are synthetic.
            let script = """
            (() => {
                const editor = document.getElementById('ime-legacy-model');
                editor.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true}));
                editor.textContent = '';
                const event = new InputEvent('beforeinput', {bubbles:true,cancelable:true,
                    inputType:'insertFromComposition',data:'こんにちは',isComposing:true});
                editor.dispatchEvent(event);
                if (!event.defaultPrevented) editor.textContent += 'こんにちは';
                editor.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true,data:'こんにちは'}));
                return JSON.stringify({length:editor.textContent.length,
                    legacy:/Version\\/[\\d.]+.*Safari/.test(navigator.userAgent),
                    webkit:/AppleWebKit(?!.*Chrome)/i.test(navigator.userAgent),
                    app:navigator.userAgent.includes('Levistica'),
                    chrome:navigator.userAgent.includes('Chrome/')});
            })();
            """
            let json: String = try await withCheckedThrowingContinuation { continuation in
                runtime.webView.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? String ?? "") }
                }
            }
            let data = try #require(json.data(using: .utf8))
            let result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let compatibilityAvailable = WebKitBrowserIdentity.applicationName.hasPrefix("Version/")
            print("Managed editor generated-event replay: compatibility=\(compatibilityAvailable), length=\(result["length"] as? Int ?? -1)")
            #expect(result["length"] as? Int == (compatibilityAvailable ? 5 : 10))
            #expect(result["legacy"] as? Bool == compatibilityAvailable)
            #expect(result["webkit"] as? Bool == true)
            #expect(result["app"] as? Bool == true)
            #expect(result["chrome"] as? Bool == false)
            #expect(runtime.webView.configuration.applicationNameForUserAgent == WebKitBrowserIdentity.applicationName)
        }
    }
}


@MainActor
struct PagePendingInputTests {
    private func context() throws -> JSContext {
        let js = try #require(JSContext())
        js.evaluateScript("""
        const handlers = {}, messages = [], tasks = [];
        const window = {webkit:{messageHandlers:{levisticaInputActivity:{postMessage(value){messages.push(value);}}}}};
        const document = {addEventListener(type, fn){(handlers[type] ||= []).push(fn);}};
        function addEventListener(type, fn){document.addEventListener(type, fn);}
        function queueMicrotask(fn){tasks.push(fn);}
        class Element {
            constructor(){this.value='';this.type='text';this.role='';this.search=false;this.isConnected=true;this.form=null;this.isContentEditable=false;}
            getAttribute(name){return name==='role'?this.role:null;}
            closest(selector){return selector==='[contenteditable]'?(this.isContentEditable?this:null):(this.search?this:null);}
        }
        class HTMLInputElement extends Element {}
        class HTMLTextAreaElement extends Element {}
        class HTMLSelectElement extends Element {}
        function fire(type, target, options={}) {
            const event = Object.assign({isTrusted:true,target,defaultPrevented:false,composedPath(){return [target];}},options);
            for(const fn of handlers[type] || []) fn(event);
            while(tasks.length)tasks.shift()();
        }
        const field = new HTMLInputElement();
        const lastPending = () => messages.at(-1).pending;
        function edit(value){fire('beforeinput',field);field.value=value;fire('input',field);}
        """)
        js.evaluateScript(PageInputGuard.source)
        try #require(js.exception == nil)
        return js
    }

    @Test func restoringTheOriginalValueStopsDepartureWarningsButKeepsActivity() throws {
        let js = try context()
        #expect(js.evaluateScript("edit('draft');lastPending()")?.toBool() == true)
        #expect(js.evaluateScript("edit('');lastPending()")?.toBool() == false)
        #expect(js.evaluateScript("messages.at(-1).revision")?.toInt32() == 2)
        #expect(js.exception == nil)
    }

    @Test(arguments: ["field.type='search'", "field.role='searchbox'", "field.search=true"])
    func semanticSearchControlsDoNotBecomeUnsentDrafts(setup: String) throws {
        let js = try context()
        js.evaluateScript(setup)
        #expect(js.evaluateScript("edit('query');lastPending()")?.toBool() == false)
        #expect(js.evaluateScript("messages.at(-1).revision")?.toInt32() == 1)
        #expect(js.exception == nil)
    }

    @Test func submittedFormsRemainCleanWhenRestoredFromHistory() throws {
        let js = try context()
        js.evaluateScript("field.form={};edit('query');fire('submit',field.form);fire('pageshow',null);")
        #expect(js.evaluateScript("lastPending()")?.toBool() == false)
        #expect(js.exception == nil)
    }

    @Test func preventedSubmissionAndUnrelatedFormsPreserveDraftProtection() throws {
        let js = try context()
        js.evaluateScript("field.form={};edit('draft');fire('submit',field.form,{defaultPrevented:true});")
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        js.evaluateScript("fire('submit',{});")
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        #expect(js.exception == nil)
    }

    @Test func resetAndDisconnectedControlsDoNotRetainPhantomDrafts() throws {
        let js = try context()
        #expect(js.evaluateScript("edit('draft');field.value='';fire('reset',{});lastPending()")?.toBool() == false)
        #expect(js.evaluateScript("edit('draft');field.isConnected=false;fire('pageshow',null);lastPending()")?.toBool() == false)
        #expect(js.exception == nil)
    }

    @Test func programmaticEventsCannotClaimTrustedEditing() throws {
        let js = try context()
        js.evaluateScript("field.value='programmatic';fire('input',field,{isTrusted:false});")
        #expect(js.evaluateScript("messages.length")?.toInt32() == 0)
        #expect(js.exception == nil)
    }

    @Test func blurChangeDoesNotCountTheSameValueAsANewEdit() throws {
        let js = try context()
        js.evaluateScript("edit('draft');fire('change',field);")
        #expect(js.evaluateScript("messages.at(-1).revision")?.toInt32() == 1)
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        js.evaluateScript("edit('new draft');fire('change',field);")
        #expect(js.evaluateScript("messages.at(-1).revision")?.toInt32() == 2)
        #expect(js.exception == nil)
    }

    @Test func syntheticLifecycleEventsCannotClearPendingDrafts() throws {
        let js = try context()
        js.evaluateScript("field.form={};edit('draft');fire('submit',field.form,{isTrusted:false});fire('pagehide',null,{isTrusted:false});")
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        js.evaluateScript("field.value='';fire('reset',field.form,{isTrusted:false});fire('pageshow',null,{isTrusted:false});")
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        #expect(js.exception == nil)
    }

    @Test func contentEditableFormattingIsAnEditEvenWhenTextDoesNotChange() throws {
        let js = try context()
        js.evaluateScript("const editor=new Element();editor.isContentEditable=true;editor.innerHTML='draft';fire('beforeinput',editor);editor.innerHTML='<b>draft</b>';fire('input',editor);")
        #expect(js.evaluateScript("lastPending()")?.toBool() == true)
        js.evaluateScript("editor.innerHTML='draft';fire('input',editor);")
        #expect(js.evaluateScript("lastPending()")?.toBool() == false)
        #expect(js.exception == nil)
    }

    @Test func frameLimitFailsConservativelyWithoutDroppingProtection() {
        var state = PageInputActivityState()
        for index in 0..<128 { state.receive(frame: "frame-\(index)", revision: 0, pending: false) }
        state.receive(frame: "overflow", revision: 1, pending: true)
        #expect(state.hasEditedInput)
        #expect(state.needsDepartureConfirmation)
        state.approveDeparture()
        #expect(state.needsDepartureConfirmation == false)
        state.receive(frame: "overflow", revision: 2, pending: true)
        #expect(state.needsDepartureConfirmation)
    }

    @Test func oneApprovalCoversRepeatedNavigationCallbacksUntilNewInput() {
        var state = PageInputActivityState()
        state.receive(frame: "main", revision: 1, pending: true)
        #expect(state.needsDepartureConfirmation)
        state.approveDeparture()
        state.receive(frame: "main", revision: 1, pending: true)
        #expect(state.needsDepartureConfirmation == false)
        #expect(state.hasEditedInput)
        state.receive(frame: "main", revision: 2, pending: true)
        #expect(state.needsDepartureConfirmation)
        state.approveDeparture()
        state.cancelDepartureApproval()
        #expect(state.needsDepartureConfirmation)
    }

    @Test func clearingOneFrameDoesNotClearAnotherFramesDraft() {
        var state = PageInputActivityState()
        state.receive(frame: "main", revision: 1, pending: true)
        state.receive(frame: "child", revision: 1, pending: true)
        state.receive(frame: "main", revision: 1, pending: false)
        #expect(state.needsDepartureConfirmation)
        state.receive(frame: "child", revision: 1, pending: false)
        #expect(state.needsDepartureConfirmation == false)
        #expect(state.hasEditedInput)
        state.receive(frame: "child", revision: 0, pending: true)
        #expect(state.needsDepartureConfirmation == false)
    }
}


extension WebKitIntegrationTests {
    @MainActor
    struct NetworkResponsePolicyTests {
        private func page() async throws -> (PageRuntime, URL) {
            let raw = try #require(ProcessInfo.processInfo.environment["LEVISTICA_FIXTURE_URL"])
            let base = try #require(URL(string: raw))
            try #require(base.scheme == "http" && base.host == "127.0.0.1" && base.port != nil)
            let runtime = PageRuntime(dataStore: .nonPersistent())
            runtime.load(base.appendingPathComponent("network-policy"))
            let deadline = ContinuousClock.now + .seconds(10)
            while runtime.webView.title != "Network policy fixture" || runtime.webView.isLoading,
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(runtime.webView.title == "Network policy fixture")
            return (runtime, base)
        }

        private func evaluate(_ script: String, in runtime: PageRuntime) async throws -> [String: Any] {
            let value = try await runtime.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
            guard let dictionary = value as? [String: Any] else { throw URLError(.cannotParseResponse) }
            return dictionary
        }

        @Test(arguments: [true, false])
        func corsExposesSafelistedHeadersOnlyWhenTheOriginIsAllowed(allowed: Bool) async throws {
            let (runtime, base) = try await page()
            defer { runtime.stop() }
            var cross = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
            cross.host = "localhost"
            cross.path = allowed ? "/network-policy-cors-allowed" : "/network-policy-cors-denied"
            let target = try #require(cross.url)
            let script = """
            try {
                const response = await fetch(\(String(reflecting: target.absoluteString)), {cache:'no-store', signal:AbortSignal.timeout(5000)});
                return {readable:true, type:response.type, length:response.headers.get('content-length'),
                    contentType:response.headers.get('content-type'), unexposed:response.headers.get('x-levistica-fixture-unexposed'), body:await response.text()};
            } catch (error) { return {readable:false, errorName:error.name}; }
            """
            let result = try await evaluate(script, in: runtime)
            #expect(result["readable"] as? Bool == allowed)
            if allowed {
                #expect(result["type"] as? String == "cors")
                #expect(result["body"] as? String == "synthetic cross-origin response")
                #expect(result["length"] as? String == String("synthetic cross-origin response".utf8.count))
                #expect(result["contentType"] as? String == "text/plain")
                #expect(result["unexposed"] is NSNull)
            } else {
                #expect(result["errorName"] as? String == "TypeError")
            }
        }

        @Test(arguments: [false, true], [false, true])
        func imageReferrerPolicyWorksBeforeAndAfterAssigningItsURL(crossOrigin: Bool, sourceFirst: Bool) async throws {
            let (runtime, base) = try await page()
            defer { runtime.stop() }
            for policy in ["no-referrer", "origin", "same-origin"] {
                var target = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
                if crossOrigin { target.host = "localhost" }
                target.path = "/network-policy-image"
                target.queryItems = [URLQueryItem(name: "case", value: policy)]
                let url = try #require(target.url)
                let script = """
                return await new Promise((resolve, reject) => {
                    const image = new Image();
                    const timer = setTimeout(() => reject(new Error('fixture image timeout')), 5000);
                    image.onload = () => { clearTimeout(timer); resolve({width:image.naturalWidth}); };
                    image.onerror = () => { clearTimeout(timer); reject(new Error('fixture image failed')); };
                    const url = \(String(reflecting: url.absoluteString)), policy = \(String(reflecting: policy));
                    if (\(sourceFirst ? "true" : "false")) { image.src = url; image.referrerPolicy = policy; }
                    else { image.referrerPolicy = policy; image.src = url; }
                });
                """
                let result = try await evaluate(script, in: runtime)
                let expected = policy == "no-referrer" || (policy == "same-origin" && crossOrigin) ? 1 : policy == "origin" ? 2 : 3
                let width = try #require(result["width"] as? Int)
                let version = Bundle(for: WKWebView.self).object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
                let affectedOrder = sourceFirst && (crossOrigin ? policy != "origin" : policy != "same-origin")
                let reproducedVersions = ["21624.4.5.11.5", "21624.5.1.11.3"]
                if reproducedVersions.contains(version) && affectedOrder {
                    // Reproduced in this OS's Safari and normal document scripts,
                    // not just native evaluation. Keep the expected policy check
                    // visible; other values or an engine fix must not be hidden.
                    let defaultWidth = crossOrigin ? 2 : 3
                    #expect(width == expected || width == defaultWidth)
                    withKnownIssue("System WebKit \(version) can send the default referrer when src precedes referrerPolicy") {
                        #expect(width == expected)
                    }
                } else {
                    #expect(width == expected, "WebKit \(version)")
                }
            }
        }

        @Test(arguments: ["no-referrer", "origin", "same-origin"], [false, true])
        func fetchReferrerPolicyIsAppliedToSameAndCrossOriginRequests(policy: String, crossOrigin: Bool) async throws {
            let (runtime, base) = try await page()
            defer { runtime.stop() }
            var target = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
            if crossOrigin { target.host = "localhost" }
            target.path = "/network-policy-referrer"
            let url = try #require(target.url)
            let script = """
            const response = await fetch(\(String(reflecting: url.absoluteString)),
                {referrerPolicy:\(String(reflecting: policy)), cache:'no-store', signal:AbortSignal.timeout(5000)});
            return await response.json();
            """
            let result = try await evaluate(script, in: runtime)
            let expected = policy == "no-referrer" || (policy == "same-origin" && crossOrigin) ? "" :
                policy == "origin" ? base.absoluteString + "/" : base.appendingPathComponent("network-policy").absoluteString
            #expect(result["referer"] as? String == expected)
        }
    }
}
