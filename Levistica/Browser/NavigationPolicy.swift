import Foundation

enum NavigationPolicy {
    static func allows(_ url: URL?, isMainFrame: Bool) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" || scheme == "http" {
            return url.host?.isEmpty == false && url.user == nil && url.password == nil
        }
        // Embedded documents need these schemes; they cannot launch native applications.
        return !isMainFrame && ["about", "blob", "data"].contains(scheme)
    }
}
