import Foundation
import Observation

@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()
    var addressDraft = ""
    var inputError: String?
    var restorationNotice: String?
    var isFindBarVisible = false
    var page: PageRuntime?

    var displayTitle: String {
        if let title = page?.title, !title.isEmpty, title != "Levistica" { return title }
        return page?.url?.host ?? "新しいタブ"
    }
}
