import SwiftUI

struct HistoryPanel: View {
    @Bindable var session: BrowserSession
    @Bindable var library: HistoryLibrary
    @State private var confirmingClear = false
    @Environment(\.openSettings) private var openSettings
    private var selected: HistoryEntry? { library.items.first { $0.id == library.selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("閲覧履歴").font(.headline)
                Spacer()
                Button("閉じる", systemImage: "xmark") { library.isVisible = false }
                    .labelStyle(.iconOnly).accessibilityIdentifier("closeHistoryButton")
            }
            TextField("名前・URLで検索", text: $library.query)
                .onSubmit { library.load() }.accessibilityIdentifier("historySearchField")
            Text("Returnで検索・直近200件まで表示").font(.caption)
            if let notice = library.notice {
                Text(notice).font(.caption).accessibilityIdentifier("historyNotice")
                Button("読み込みを再試行") { library.load() }
            }
            List(selection: $library.selectedID) {
                ForEach(library.items) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.visited, format: .dateTime.month().day().hour().minute()).font(.caption)
                    }.tag(item.id)
                }
            }.accessibilityIdentifier("historyList")
            if let selected {
                Button("新しいタブで開く") {
                    guard session.newTab() != nil else { return }
                    _ = session.navigate(selected.url.absoluteString)
                }.accessibilityIdentifier("openHistoryButton")
                Button("この履歴を削除") { library.removeSelected() }
                    .disabled(library.isBusy).accessibilityIdentifier("deleteHistoryButton")
            }
            if confirmingClear {
                Text("閲覧履歴をすべて削除します。元には戻せません。開いているタブ、ブックマーク、ログイン情報は残ります。")
                    .font(.caption)
                Button("すべて削除する", role: .destructive) { library.clear(); confirmingClear = false }
                    .disabled(library.isBusy).accessibilityIdentifier("confirmClearHistoryButton")
                Button("やめる") { confirmingClear = false }
            } else {
                Button("履歴をすべて削除…") { confirmingClear = true }
                    .disabled(library.isBusy).accessibilityIdentifier("clearHistoryButton")
            }
            Text("\(library.items.count)件表示").font(.caption).accessibilityIdentifier("historyResultCount")
            Button("履歴の設定…") {
                session.settingsSection = .history
                openSettings()
            }.accessibilityIdentifier("historySettingsLink")
            Text(library.preferences.recordingEnabled ? "履歴を記録中" : "履歴の記録は停止中")
                .font(.caption).accessibilityIdentifier("historyRecordingStatus")
            Text("保存は\(library.preferences.retentionDays)日以内・最大10000件。同じURLは最新の訪問だけを残します。")
                .font(.caption).foregroundStyle(.secondary)
            if !library.isPersistent { Text("この起動だけ保存します。終了すると消えます。").font(.caption) }
        }
        .padding(12)
    }
}
