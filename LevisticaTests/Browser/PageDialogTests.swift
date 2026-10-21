import Testing
@testable import Levistica

@MainActor
struct PageDialogTests {
    @Test func siteDialogTextIsBoundedEvenForCombiningCharacters() {
        let combining = "a" + String(repeating: "\u{0301}", count: 10000)
        let bounded = PageDialogController.boundedText(combining)
        #expect(bounded.utf16.count == 4096)
        #expect(PageDialogController.boundedText("short message") == "short message")
        #expect(PageDialogController.boundedText(String(repeating: "😀", count: 3000)).utf16.count == 4096)
    }

    @Test func invisiblePromptCompletesWithCancellationExactlyOnce() {
        let controller = PageDialogController()
        var calls = 0
        controller.present(message: "synthetic prompt", origin: "http://127.0.0.1", window: nil,
                           allowsCancel: true, promptDefault: "synthetic default", isPrompt: true) { accepted, value in
            calls += 1
            #expect(!accepted)
            #expect(value == nil)
        }
        #expect(calls == 1)
        #expect(controller.notice != nil)
        controller.cancel()
        #expect(calls == 1)
        controller.beginDocument()
        #expect(controller.notice == nil)
    }
}
