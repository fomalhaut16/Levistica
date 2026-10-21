import SwiftUI

struct SiteDataSettingsView: View {
    @Bindable var library: SiteDataLibrary
    @State private var query = ""
    @State private var confirming: Removal?
    private enum Removal {
        case selected(UUID, String), all
        var explanation: String {
            switch self {
            case let .selected(_, name): "「\(name)」のCookieとサイト内の保存データを削除します。同じドメインの関連ページにも影響します。"
            case .all: "このLevisticaに保存された、すべてのサイトのCookieとサイト内の保存データを削除します。"
            }
        }
    }
    private var selected: SiteDataEntry? { library.items.first { $0.id == library.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("サイトデータ").font(.title2)
            Text("このLevisticaが使うサイトデータだけを扱います。SafariやChromeの保存先は変更しません。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField("表示中のドメインを検索", text: $query).accessibilityIdentifier("siteDataSearchField")
                Button(library.hasLoaded ? "一覧を更新" : "一覧を表示") { library.load() }
                    .accessibilityIdentifier("loadSiteDataButton")
            }.disabled(library.isBusy || confirming != nil)
            List(selection: $library.selectedID) {
                ForEach(library.items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }) { item in
                    VStack(alignment: .leading) {
                        Text(item.name).lineLimit(1)
                        Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(item.id)
                }
            }.accessibilityIdentifier("siteDataList").disabled(library.isBusy || confirming != nil)
            if let confirming {
                Text(confirming.explanation + "ログアウトやサイトでの作業に影響します。元には戻せません。")
                    .font(.callout).accessibilityIdentifier("siteDataConfirmation")
                HStack {
                    Button("やめる") { self.confirming = nil }.accessibilityIdentifier("cancelSiteDataRemovalButton")
                    Button("削除する", role: .destructive) {
                        switch confirming {
                        case let .selected(id, _): library.delete(id)
                        case .all: library.deleteAll()
                        }
                        self.confirming = nil
                    }.accessibilityIdentifier("confirmSiteDataRemovalButton")
                }
            } else {
                HStack {
                    Button("選択したサイトを削除…") {
                        if let selected { confirming = .selected(selected.id, selected.name) }
                    }.disabled(selected == nil || library.isBusy).accessibilityIdentifier("deleteSelectedSiteDataButton")
                    Button("すべて削除…") { confirming = .all }
                        .disabled(!library.hasLoaded || library.isBusy || library.totalCount == 0)
                        .accessibilityIdentifier("deleteAllSiteDataButton")
                }
            }
            if library.isBusy { Text(library.isDeleting ? "削除して結果を確認中…" : "一覧を取得中…") }
            if let notice = library.notice { Text(notice).font(.callout).accessibilityIdentifier("siteDataNotice") }
            Text("\(library.totalCount)件・表示は先頭1000件まで").font(.caption).accessibilityIdentifier("siteDataCount")
            Text("開いたページは再読み込みしません。ページがデータを保存し直す場合があります。履歴、ブックマーク、タブ一覧、保存済みのダウンロードは残ります。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
