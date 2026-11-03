import SwiftUI

struct PrivacySettingsView: View {
    let preferences: BrowserPreferences
    let history: HistoryLibrary
    let siteData: SiteDataLibrary
    let protection: SafeBrowsingProtection
    @Binding var section: BrowserSession.SettingsSection
    var body: some View {
        TabView(selection: $section) {
            GeneralPreferencesView(preferences: preferences)
                .tabItem { Label("一般", systemImage: "gearshape") }.tag(BrowserSession.SettingsSection.general)
            HistoryPreferencesView(history: history).tabItem { Label("履歴", systemImage: "clock") }.tag(BrowserSession.SettingsSection.history)
            SiteDataSettingsView(library: siteData).tabItem { Label("サイトデータ", systemImage: "externaldrive") }.tag(BrowserSession.SettingsSection.siteData)
            ProtectionPreferencesView(protection: protection)
                .tabItem { Label("危険サイト保護", systemImage: "shield") }.tag(BrowserSession.SettingsSection.protection)
        }.frame(width: 620, height: 540)
    }
}

private struct GeneralPreferencesView: View {
    let preferences: BrowserPreferences
    @State private var draft = ""
    @State private var homeDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("新しいタブで開くページ").font(.title2)
                TextField("URL（空欄で空白ページ）", text: $draft)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("newTabPageField")
                    .accessibilityLabel("新しいタブで開くURL")
                    .disabled(!preferences.canSave)
                HStack {
                    Button("Google") { draft = "https://www.google.com/" }.accessibilityIdentifier("useGoogleNewTabButton")
                        .accessibilityLabel("新しいタブのURLにGoogleを入力")
                    Button("空白ページ") { draft = "" }.accessibilityIdentifier("useBlankNewTabButton")
                        .accessibilityLabel("新しいタブのURLを空にする")
                    Spacer()
                    Button("保存") { if preferences.saveNewTabPage(draft) { draft = preferences.newTabURL?.absoluteString ?? "" } }
                        .accessibilityIdentifier("saveNewTabPageButton")
                        .accessibilityLabel("新しいタブのページを保存")
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
                Divider()
                Text("ホームページ").font(.title2)
                TextField("URL（空欄で未設定）", text: $homeDraft)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("homePageField")
                    .accessibilityLabel("ホームページのURL")
                    .disabled(!preferences.canSave)
                HStack {
                    Button("Google") { homeDraft = "https://www.google.com/" }.accessibilityIdentifier("useGoogleHomeButton")
                        .accessibilityLabel("ホームページのURLにGoogleを入力")
                    Button("未設定") { homeDraft = "" }.accessibilityIdentifier("clearHomePageButton")
                        .accessibilityLabel("ホームページのURLを空にする")
                    Spacer()
                    Button("保存") {
                        if preferences.saveHomePage(homeDraft) { homeDraft = preferences.homeURL?.absoluteString ?? "" }
                    }.accessibilityIdentifier("saveHomePageButton")
                        .accessibilityLabel("ホームページを保存")
                }.disabled(!preferences.canSave)
                Text("「ページ」メニューの「ホームページを開く」またはCmd-Shift-Hで開きます。新規タブのページや前回のタブ復元とは別の設定です。")
                    .font(.callout).foregroundStyle(.secondary)
                if !preferences.isPersistent { Text("この起動だけの設定です。終了すると消えます。").font(.caption) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if let notice = preferences.notice {
                Text(notice).font(.caption).accessibilityIdentifier("newTabPageNotice")
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
        .onAppear {
            draft = preferences.newTabURL?.absoluteString ?? ""
            homeDraft = preferences.homeURL?.absoluteString ?? ""
        }
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


private struct ProtectionPreferencesView: View {
    let protection: SafeBrowsingProtection
    @State private var state = SafeBrowsingProtection.State.stopped
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("危険サイト保護の補完").font(.title2)
            Text("Googleの脅威一覧を端末に保存し、一致候補のハッシュの一部だけを照会します。照会時には送信元IPもGoogleへ伝わります。URL全体やフォームの内容は送りません。")
            Text(status).accessibilityIdentifier("safeBrowsingProtectionStatus")
            HStack {
                Button("保護を開始") {
                    state = .starting
                    Task { state = await protection.startAfterUserRequest() }
                }.disabled(state == .starting || state == .ready)
                    .accessibilityIdentifier("startSafeBrowsingProtectionButton")
                Button("停止") { Task { await protection.stop(); state = .stopped } }
                    .accessibilityIdentifier("stopSafeBrowsingProtectionButton")
            }
            Text("開始時に、専用APIキーを読むためのキーチェーン認証が表示される場合があります。この起動中だけ有効にします。終了後は、次の起動で開始してください。")
            Text("一覧の準備中や通信失敗時は、追加の照合を完了できません。Googleの情報には誤検知や検知漏れがあります。WebKit標準の警告とTLS検証は常に維持します。")
            Link("Google Safe Browsingについて", destination: URL(string: "https://safebrowsing.google.com/")!)
            Spacer()
        }.padding(24)
        .task {
            while !Task.isCancelled {
                state = await protection.currentState()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    private var status: String {
        switch state {
        case .stopped: "追加の保護は停止中です。"
        case .starting: "認証と一覧の準備を行っています。"
        case .ready: "3一覧の準備ができています。ページを開くときに照合します。"
        case .keyUnavailable(.missing): "専用APIキーが見つかりません。"
        case .keyUnavailable(.denied), .keyUnavailable(.authorizationRequired): "キーの読み取りが許可されていません。"
        case .keyUnavailable: "APIキーを使用できません。"
        case .unavailable(.disabled): "この検証用ビルドでは通常版のキーを使いません。"
        case .unavailable(.authentication): "APIの認証に失敗しています。キーの設定を確認してください。"
        case .unavailable(.quota): "APIの利用上限に達しました。追加の照合は一時的に利用できません。"
        case .unavailable: "追加の照合を完了できていません。時間を置いて一覧の更新を試みます。"
        }
    }
}
