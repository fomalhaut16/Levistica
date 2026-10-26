import SwiftUI

struct BrowserRootView: View {
    @Bindable var session: BrowserSession
    @State private var confirmingBackupRecovery = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HSplitView {
                    TabSidebar(session: session)
                    tabContent(session.activeTab)
                        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
                DownloadShelf(manager: session.downloads)
            }
            if session.history.isVisible {
                Divider()
                HistoryPanel(session: session, library: session.history).frame(width: 320)
            } else if session.isBookmarkListVisible {
                Divider()
                BookmarkPanel(session: session, library: session.bookmarks)
                    .frame(width: 320)
            }
        }
        .frame(minWidth: (session.isBookmarkListVisible || session.history.isVisible) ? 1120 : 800, minHeight: 420)
        .alert("バックアップから一覧を復旧しますか？", isPresented: $confirmingBackupRecovery) {
            Button("一覧を復旧") { session.restoreSessionBackup() }
                .accessibilityIdentifier("confirmRestoreSessionBackupButton")
            Button("キャンセル", role: .cancel) { }
        } message: {
            Text("最後の正常終了時の一覧を戻します。元の保存ファイルを残し、ページを開くかは復旧後に選べます。")
        }
    }

    private func tabContent(_ tab: BrowserTab) -> some View {
        VStack(spacing: 0) {
            BrowserNavigationBar(session: session, tab: tab).id(tab.id)
            if let notice = session.externalOpenNotice {
                HStack {
                    Text(notice).accessibilityIdentifier("externalOpenNotice")
                    Spacer()
                    Button("閉じる") { session.externalOpenNotice = nil }
                }.padding(8)
            }
            if let notice = tab.sleepNotice {
                HStack {
                    Text(notice).accessibilityIdentifier("tabSleepNotice")
                    Spacer()
                    Button("閉じる") { tab.sleepNotice = nil }
                }.padding(8)
            }
            if tab.isLocalPDF {
                HStack {
                    Text(tab.page == nil ? "PDFを選び直してください。" : "ローカルPDFの閲覧中です。入力・注釈は保存しません。")
                        .accessibilityIdentifier("localPDFNotice")
                    Spacer()
                    if tab.page == nil { Button("PDFを選び直す") { session.chooseLocalPDF(replacing: tab.id) } }
                }.font(.caption).padding(8)
            }
            if tab.page?.isPDF == true && !tab.isLocalPDF {
                Text("PDFの閲覧中です。入力・注釈の保存には対応していません。")
                    .font(.caption).padding(8).accessibilityIdentifier("webPDFNotice")
            }
            if let origin = tab.openerOrigin {
                Text("別タブの要求元: \(origin)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .lineLimit(1).padding(.horizontal, 10).padding(.vertical, 4)
                    .accessibilityIdentifier("pageOpenerOrigin")
            }
            if let dialogs = tab.page?.dialogs, let notice = dialogs.notice {
                HStack {
                    Text(notice).accessibilityIdentifier("siteDialogNotice")
                    Spacer()
                    Button("閉じる") { dialogs.notice = nil }
                }.padding(8)
            }
            if let notice = session.history.notice, !session.history.isVisible {
                HStack {
                    Text(notice).font(.caption).accessibilityIdentifier("historyStorageNotice")
                    Spacer()
                    Button("履歴を確認") { session.showHistory() }
                }.padding(8)
            }
            if let message = session.storageFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).accessibilityIdentifier("storageFailure")
                    if let count = session.recoveryBackupTabCount {
                        let date = session.recoveryBackupDate?.formatted(date: .numeric, time: .shortened) ?? "日時不明"
                        Text("最後の正常終了: \(date)・\(count)タブ")
                            .font(.caption).accessibilityIdentifier("sessionBackupInfo")
                        Button("バックアップから復旧…") { confirmingBackupRecovery = true }
                            .disabled(!session.canRestoreSessionBackup)
                            .accessibilityIdentifier("restoreSessionBackupButton")
                        if !session.canRestoreSessionBackup {
                            Text("復旧は新しいページを開く前に行ってください。必要なら終了して起動し直してください。")
                                .font(.caption)
                        }
                    } else if session.hasStorageRecoverySource {
                        Text("利用できるバックアップが見つかりません。元の保存ファイルを残しています。")
                            .font(.caption)
                    }
                    HStack {
                        Button("保存を再試行") { session.persistSession() }.disabled(!session.canRetryPersistence)
                        Button("保存せず終了") {
                            session.discardUnsavedChangesOnQuit = true
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            if session.recoveryRequired {
                HStack {
                    Text(session.recoveryMessage)
                        .accessibilityIdentifier("sessionRecoveryNotice")
                    Spacer()
                    Button("選択中のページを開く") { session.resumeSelectedTab() }
                        .disabled(tab.pendingURL == nil || !tab.mayRestoreAutomatically || tab.isSleeping)
                }.padding(8)
            }
            if let message = tab.inputError ?? tab.page?.failure {
                HStack {
                    Text(message).textSelection(.enabled).accessibilityIdentifier("errorMessage")
                    Spacer()
                    if tab.inputError == nil && tab.page?.canRetry == true {
                        Button("再試行") { tab.page?.retry() }
                    }
                    Button("閉じる") { tab.inputError = nil; tab.page?.dismissFailure() }
                }
                .padding(10).background(.regularMaterial)
            }
            if let notice = tab.restorationNotice {
                HStack {
                    Text(notice).font(.caption)
                    Spacer()
                    Button("閉じる") { tab.restorationNotice = nil }
                }.padding(8)
            }
            if let page = tab.page, tab.isFindBarVisible {
                PageFindBar(session: session, tab: tab, page: page).id(tab.id)
            }
            Divider()
            ZStack {
                // Session owns the loaded pages. This stable host only manages their
                // attachment, visibility and selected viewport; it never starts a load.
                WebPageView(pages: session.tabs.compactMap(\.page), selectedPage: tab.page)
                    .accessibilityIdentifier("pageView")
                    .overlay(alignment: .top) {
                        if let page = tab.page, page.isLoading {
                            ProgressView(value: page.progress).progressViewStyle(.linear)
                        }
                    }
                if tab.page == nil {
                    if tab.isSleeping {
                        VStack(spacing: 12) {
                            Image(systemName: "moon.zzz").font(.largeTitle)
                            Text("タブは休眠中です").font(.headline).accessibilityIdentifier("sleepingTabPlaceholder")
                            Text("再開するとURLから読み込み直します。前のページの入力や再生位置は復元されません。")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("ページを再開") { session.resumeSleepingTab() }
                                .accessibilityIdentifier("resumeSleepingTabButton")
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if session.recoveryRequired && tab.pendingURL != nil && tab.mayRestoreAutomatically {
                        ContentUnavailableView("ページはまだ読み込んでいません", systemImage: "globe",
                                               description: Text("上の「選択中のページを開く」から表示できます。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("Levistica", systemImage: "globe",
                                               description: Text("URLを入力してページを開きます。"))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}
