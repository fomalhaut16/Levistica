import Observation
import WebKit

@MainActor
@Observable
final class BrowserSession {
    private(set) var page: PageRuntime?
    var inputError: String?
    var addressFocusRequest = 0

    func navigate(_ input: String) -> Bool {
        do {
            let url = try AddressResolver.resolve(input)
            inputError = nil
            if page == nil {
                #if DEBUG
                let isolated = ProcessInfo.processInfo.environment["LEVISTICA_EPHEMERAL"] == "1"
                page = PageRuntime(dataStore: isolated ? .nonPersistent() : .default())
                #else
                page = PageRuntime()
                #endif
            }
            page?.load(url)
            return true
        } catch {
            inputError = error.localizedDescription
            return false
        }
    }
}
