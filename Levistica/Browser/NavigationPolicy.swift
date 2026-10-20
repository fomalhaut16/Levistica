import Foundation

enum NavigationPolicy {
    // WHATWG Fetch §2.9, checked 2026-10-20: https://fetch.spec.whatwg.org/#port-blocking
    // Reject explicitly so a WebKit-rejected port cannot leave an unexplained blank page.
    private static let restrictedPorts: Set<Int> = [
        0, 1, 7, 9, 11, 13, 15, 17, 19, 20, 21, 22, 23, 25, 37, 42, 43, 53, 69,
        77, 79, 87, 95, 101, 102, 103, 104, 109, 110, 111, 113, 115, 117, 119, 123,
        135, 137, 139, 143, 161, 179, 389, 427, 465, 512, 513, 514, 515, 526, 530,
        531, 532, 540, 548, 554, 556, 563, 587, 601, 636, 989, 990, 993, 995, 1719,
        1720, 1723, 2049, 3659, 4045, 4190, 5060, 5061, 6000, 6566, 6665, 6666,
        6667, 6668, 6669, 6679, 6697, 10080
    ]

    static func isRestrictedPort(_ port: Int?) -> Bool {
        port.map(restrictedPorts.contains) ?? false
    }

    static func allowsNewContext(_ url: URL?) -> Bool {
        // window.open() may create an empty related page before assigning its URL.
        isBlankContextURL(url) || allows(url, isMainFrame: true)
    }

    static func isBlankContextURL(_ url: URL?) -> Bool {
        url == nil || url?.absoluteString.isEmpty == true || url?.absoluteString == "about:blank"
    }

    static func allows(_ url: URL?, isMainFrame: Bool) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" || scheme == "http" {
            return url.host?.isEmpty == false && url.user == nil && url.password == nil
                && !isRestrictedPort(url.port)
        }
        // Embedded documents need these schemes; they cannot launch native applications.
        return !isMainFrame && ["about", "blob", "data"].contains(scheme)
    }
}
