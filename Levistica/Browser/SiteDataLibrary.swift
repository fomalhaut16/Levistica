import Observation
import WebKit

struct SiteDataEntry: Identifiable {
    let id: UUID
    let name: String
    let summary: String
}

@MainActor @Observable
final class SiteDataLibrary {
    private(set) var items: [SiteDataEntry] = []
    private(set) var totalCount = 0
    private(set) var hasLoaded = false
    private(set) var isBusy = false
    private(set) var isDeleting = false
    var selectedID: UUID?
    var notice: String?
    @ObservationIgnored private let provider: () -> WKWebsiteDataStore?
    @ObservationIgnored private var records: [UUID: WKWebsiteDataRecord] = [:]
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(provider: @escaping () -> WKWebsiteDataStore?) { self.provider = provider }
    func flush() async { await pending?.value }

    func load() {
        guard !isBusy else { return }
        guard let store = provider() else { notice = "この起動のサイトデータを開けませんでした。"; return }
        isBusy = true
        notice = nil
        pending = Task {
            defer { isBusy = false; pending = nil }
            apply(await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()))
        }
    }

    func delete(_ id: UUID) {
        guard !isBusy else { return }
        guard let record = records[id] else { notice = "一覧が変わりました。対象を選び直してください。"; return }
        remove(record)
    }
    func deleteAll() { guard !isBusy else { return }; remove(nil) }

    private func remove(_ target: WKWebsiteDataRecord?) {
        guard let store = provider() else { notice = "この起動のサイトデータを開けませんでした。"; return }
        isBusy = true
        isDeleting = true
        notice = nil
        pending = Task {
            defer { isBusy = false; isDeleting = false; pending = nil }
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            if let target { await store.removeData(ofTypes: types, for: [target]) }
            else { await store.removeData(ofTypes: types, modifiedSince: .distantPast) }
            let remaining = await store.dataRecords(ofTypes: types)
            let stillPresent = target.map { item in remaining.contains { $0.displayName == item.displayName } } ?? !remaining.isEmpty
            apply(remaining)
            notice = stillPresent
                ? "対象のデータが残っています。開いているページが保存し直す場合があります。タブを閉じてから再試行してください。"
                : "削除後の一覧に対象のデータはありません。"
        }
    }

    private func apply(_ found: [WKWebsiteDataRecord]) {
        totalCount = found.count
        records = [:]
        items = found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .prefix(1000).map { record in
                let id = UUID()
                records[id] = record
                var parts: [String] = []
                if record.dataTypes.contains(WKWebsiteDataTypeCookies) { parts.append("Cookie") }
                if !record.dataTypes.subtracting([WKWebsiteDataTypeCookies]).isEmpty { parts.append("キャッシュ・サイト内の保存データ") }
                return SiteDataEntry(id: id, name: record.displayName, summary: parts.joined(separator: "、"))
            }
        selectedID = nil
        hasLoaded = true
    }
}
