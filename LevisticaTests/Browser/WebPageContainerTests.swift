import AppKit
import Testing
import WebKit
@testable import Levistica

extension WebKitIntegrationTests {
@MainActor
struct WebPageContainerTests {
    private func view() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    @Test func switchingAndBlankSelectionKeepInactiveViewsAttached() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = WebPageContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let first = view(), second = view()
        host.display([first, second], selected: first)
        #expect(first.window === window && second.window === window)
        #expect(first.isHidden == false && second.isHidden)
        #expect(first.frame == host.bounds)
        host.display([first, second], selected: second)
        let inactiveFrame = first.frame
        host.frame.size.height = 449
        host.layout()
        #expect(first.frame == inactiveFrame)
        #expect(second.frame == host.bounds)
        #expect(first.window === window && first.isHidden)
        host.display([first, second], selected: nil)
        #expect(first.window === window && second.window === window)
        #expect(first.isHidden && second.isHidden)
        #expect(window.isVisible == false)
    }

    @Test func removedViewsAreDetachedAndReleased() async throws {
        let host = WebPageContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        weak var removed: WKWebView?
        autoreleasepool {
            let page = view()
            removed = page
            host.display([page], selected: page)
            host.display([], selected: nil)
            #expect(page.superview == nil)
            #expect(host.subviews.isEmpty)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while removed != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(removed == nil)
    }

    @Test func hidingFocusedContentDoesNotLeaveInputOnAnInactivePage() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let host = WebPageContainer(frame: root.bounds)
        let outsideEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        root.addSubview(host)
        root.addSubview(outsideEditor)
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let first = view(), second = view()
        host.display([first, second], selected: first)
        let pageEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        first.addSubview(pageEditor)
        #expect(window.makeFirstResponder(pageEditor))
        host.display([first, second], selected: second)
        #expect(window.firstResponder !== pageEditor)
        if let responder = window.firstResponder as? NSView {
            #expect(responder.isDescendant(of: first) == false)
        }
        #expect(window.makeFirstResponder(outsideEditor))
        host.display([first, second], selected: first)
        #expect(window.firstResponder === outsideEditor)
    }

    @Test func temporaryExternalOwnerIsNotReparentedOrResized() {
        let host = WebPageContainer(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let page = view()
        host.display([page], selected: page)
        let external = NSView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        external.addSubview(page)
        page.frame = external.bounds
        host.frame.size = NSSize(width: 320, height: 240)
        host.display([page], selected: page)
        host.layout()
        #expect(page.superview === external)
        #expect(page.frame == external.bounds)
        page.removeFromSuperview()
        host.display([page], selected: page)
        #expect(page.superview === host)
        #expect(page.frame == host.bounds)
    }
}
}
