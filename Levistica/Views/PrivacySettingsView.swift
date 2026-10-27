import SwiftUI

struct PrivacySettingsView: View {
    let preferences: BrowserPreferences
    let history: HistoryLibrary
    let siteData: SiteDataLibrary
    @Binding var section: BrowserSession.SettingsSection
    var body: some View {
        TabView(selection: $section) {
            GeneralPreferencesView(preferences: preferences)
                .tabItem { Label("一般", systemImage: "gearshape") }.tag(BrowserSession.SettingsSection.general)
            HistoryPreferencesView(history: history).tabItem { Label("履歴", systemImage: "clock") }.tag(BrowserSession.SettingsSection.history)
            SiteDataSettingsView(library: siteData).tabItem { Label("サイトデータ", systemImage: "externaldrive") }.tag(BrowserSession.SettingsSection.siteData)
        }.frame(width: 620, height: 540)
    }
}

private struct GeneralPreferencesView: View {
    let preferences: BrowserPreferences
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("新しいタブで開くページ").font(.title2)
                TextField("URL（空欄で空白ページ）", text: $draft)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("newTabPageField")
                    .disabled(!preferences.canSave)
                HStack {
                    Button("Google") { draft = "https://www.google.com/" }.accessibilityIdentifier("useGoogleNewTabButton")
                    Button("空白ページ") { draft = "" }.accessibilityIdentifier("useBlankNewTabButton")
                    Spacer()
                    Button("保存") { if preferences.saveNewTabPage(draft) { draft = preferences.newTabURL?.absoluteString ?? "" } }
                        .accessibilityIdentifier("saveNewTabPageButton")
                }.disabled(!preferences.canSave)
                Text("＋やCmd-Tでタブを追加するときに開きます。空欄ではページを読み込みません。前回のタブの復元には影響しません。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Picker("URL欄の検索先", selection: Binding(
                    get: { preferences.searchEngine },
                    set: { _ = preferences.saveSearchEngine($0) }
                )) {
                    ForEach(SearchEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .accessibilityIdentifier("addressSearchEnginePicker")
                .disabled(!preferences.canSave)
                Text("URL欄に検索語を入力してReturnを押すと、選んだ検索先を開きます。入力中の候補取得は行いません。新規タブのページや開いているタブは変わりません。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Picker("タブの配置", selection: Binding(
                    get: { preferences.tabLayout },
                    set: { _ = preferences.saveTabLayout($0) }
                )) {
                    ForEach(BrowserPreferences.TabLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .accessibilityIdentifier("tabLayoutPicker")
                .disabled(!preferences.canSave)
                Text("配置を切り替えても、タブの並びと表示中のページを保ちます。横タブでは一覧ボタンからタブを検索できます。")
                    .font(.callout).foregroundStyle(.secondary)
                if let notice = preferences.notice { Text(notice).accessibilityIdentifier("newTabPageNotice") }
                if !preferences.isPersistent { Text("この起動だけの設定です。終了すると消えます。").font(.caption) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { draft = preferences.newTabURL?.absoluteString ?? "" }
    }
}

private struct HistoryPreferencesView: View {
    @Bindable var history: HistoryLibrary
    @State private var pendingDays: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("閲覧履歴の設定").font(.title2)
            Toggle("閲覧履歴を記録する", isOn: Binding(
                get: { history.preferences.recordingEnabled },
                set: { history.setPreferences(HistoryPreferences(recordingEnabled: $0, retentionDays: history.preferences.retentionDays)) }
            ))
            .accessibilityIdentifier("recordHistoryToggle")
            .disabled(!history.preferencesLoaded || history.isBusy || pendingDays != nil)
            Text("停止すると今後の訪問とタイトル更新を記録しません。既存の履歴やログイン情報は残ります。再開しても停止中の訪問は追加しません。")
                .font(.callout).foregroundStyle(.secondary)
            Picker("履歴の保存期間", selection: Binding(
                get: { history.preferences.retentionDays },
                set: { days in
                    if days < history.preferences.retentionDays { pendingDays = days }
                    else { apply(days) }
                }
            )) {
                ForEach(HistoryPreferences.allowedDays, id: \.self) { days in Text("\(days)日").tag(days) }
            }
            .accessibilityIdentifier("historyRetentionPicker")
            .disabled(!history.preferencesLoaded || history.isBusy || pendingDays != nil)
            if let days = pendingDays {
                Text("\(days)日を超えた履歴を削除して変更します。削除した履歴は戻せません。開いているタブ、ブックマーク、ログイン情報は残ります。")
                HStack {
                    Button("やめる") { pendingDays = nil }.accessibilityIdentifier("cancelHistoryRetentionButton")
                    Button("削除して変更", role: .destructive) { apply(days); pendingDays = nil }
                        .accessibilityIdentifier("confirmHistoryRetentionButton")
                }
            }
            Text("記録・一覧表示・期間変更時に古い履歴を整理します。最大10000件で、期間を延ばしても削除済みの履歴は戻りません。")
                .font(.callout).foregroundStyle(.secondary)
            if let notice = history.notice {
                Text(notice).accessibilityIdentifier("historySettingsNotice")
                Button("読み込みを再試行") { history.load() }
            }
            if !history.isPersistent { Text("この起動だけの設定です。終了すると消えます。").font(.caption) }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { history.load() }
    }

    private func apply(_ days: Int) {
        history.setPreferences(HistoryPreferences(recordingEnabled: history.preferences.recordingEnabled, retentionDays: days))
    }
}
