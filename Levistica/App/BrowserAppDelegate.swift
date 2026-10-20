import AppKit

@MainActor
final class BrowserAppDelegate: NSObject, NSApplicationDelegate {
    weak var session: BrowserSession?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        session?.prepareToQuit() == false ? .terminateCancel : .terminateNow
    }
}
