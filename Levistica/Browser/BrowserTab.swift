import Foundation
import Observation

@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id: UUID
    var isLocalPDF = false
    var pendingURL: URL?
    var mayRestoreAutomatically = true
    var storedTitle = ""
    var openerID: UUID?
    var openerOrigin: String?

    init(id: UUID = UUID()) { self.id = id }
    var addressDraft = ""
    var inputError: String?
    var restorationNotice: String?
    var isFindBarVisible = false
    var page: PageRuntime?

    var displayTitle: String {
        if let title = page?.title, !title.isEmpty, title != "Levistica" { return title }
        return storedTitle.isEmpty ? (page?.url?.host ?? "新しいタブ") : storedTitle
    }
}
