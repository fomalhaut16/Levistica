import SwiftUI
import UniformTypeIdentifiers

struct BookmarkPanel: View {
    @Bindable var session: BrowserSession
    @Bindable var library: BookmarkLibrary
    @State private var query = ""
    @State private var titleDraft = ""
    @State private var folder: [String]?
    @State private var choosingImport = false

    private var selected: Bookmark? { filtered.first { $0.id == library.selectedID } }
    private var filtered: [Bookmark] {
        library.items.filter { item in
            (folder == nil || item.folders == folder) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
                || item.url.absoluteString.localizedCaseInsensitiveContains(query)
                || item.folders.joined(separator: " / ").localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ブックマーク").font(.headline)
                Spacer()
                Button("閉じる", systemImage: "xmark") { session.isBookmarkListVisible = false }
                    .labelStyle(.iconOnly).accessibilityIdentifier("closeBookmarksButton")
            }
            TextField("名前・URLで検索", text: $query).accessibilityIdentifier("bookmarkSearchField")
            Picker("フォルダー", selection: $folder) {
                Text("すべて").tag(Optional<[String]>.none)
                ForEach(Array(Set(library.items.map(\.folders))).sorted { $0.lexicographicallyPrecedes($1) }, id: \.self) { path in
                    Text(path.isEmpty ? "フォルダーなし" : path.joined(separator: " / ")).tag(Optional(path))
                }
            }.accessibilityIdentifier("bookmarkFolderPicker")
            Button("HTMLから取り込む…") { chooseImport() }
                .disabled(choosingImport || library.isPreparingImport || library.importPreview != nil)
                .accessibilityIdentifier("importBookmarksButton")
            if library.isPreparingImport { ProgressView("ブックマークを確認中") }
            if let count = library.importCompletionCount {
                Text("\(count)件のブックマークを取り込みました。")
                    .font(.caption).accessibilityIdentifier("bookmarkImportResult")
            }
            if let notice = library.notice {
                Text(notice).font(.caption).accessibilityIdentifier("bookmarkNotice")
                Button("読み込みを再試行") { library.load() }
            }
            List(selection: $library.selectedID) {
                ForEach(filtered) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
                        if !item.folders.isEmpty {
                            Text(item.folders.joined(separator: " / ")).font(.caption).lineLimit(1)
                        }
                        Text(item.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(item.id)
                }
            }.accessibilityIdentifier("bookmarkList")
            if let selected {
                TextField("ブックマークの名前", text: $titleDraft).accessibilityIdentifier("bookmarkTitleField")
                    .onSubmit { library.renameSelected(titleDraft) }
                HStack {
                    Button("名前を保存") { library.renameSelected(titleDraft) }.accessibilityIdentifier("saveBookmarkTitleButton")
                    Button("削除") { library.removeSelected() }.accessibilityIdentifier("deleteBookmarkButton")
                }
                Button("新しいタブで開く") {
                    _ = session.newTab(opening: selected.url)
                }.accessibilityIdentifier("openBookmarkButton")
            }
            if library.recentlyDeleted != nil {
                Button("削除を元に戻す") { library.undoRemoval() }.accessibilityIdentifier("undoBookmarkDeletionButton")
            }
            Text("\(library.items.count)件・上限1000件").font(.caption).foregroundStyle(.secondary)
            if !library.isPersistent {
                Text("この起動だけ保存します。終了すると消えます。").font(.caption)
            }
        }
        .padding(12)
        .sheet(isPresented: Binding(get: { library.importPreview != nil }, set: { if !$0 { library.cancelImport() } })) {
            if let preview = library.importPreview {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ブックマークを取り込む").font(.headline)
                    Text("追加予定\(library.plannedImportCount)件・既存と重複\(preview.entries.count - library.plannedImportCount)件")
                        .accessibilityIdentifier("bookmarkImportCounts")
                    Text("ファイル内の重複\(preview.repeatedCount)件・対象外のリンク\(preview.rejectedCount)件・空のフォルダー\(preview.emptyFolderCount)件")
                        .font(.caption)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(preview.entries.prefix(20).enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading) {
                                    Text(entry.title).lineLimit(1)
                                    Text(entry.url.absoluteString).font(.caption).lineLimit(1)
                                    if !entry.folders.isEmpty {
                                        Text(entry.folders.joined(separator: " / ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 180)
                    if preview.entries.count > 20 { Text("最初の20件を表示しています。").font(.caption) }
                    Text("既存の項目は変更しません。同じURLでもフォルダーが異なる項目は残します。空のフォルダーは取り込みません。")
                    if library.items.count + library.plannedImportCount > 1000 {
                        Text("上限1000件を超えます。不要な項目を整理してから取り込んでください。")
                    }
                    if let notice = library.notice { Text(notice).accessibilityIdentifier("bookmarkImportFailure") }
                    HStack {
                        Button("キャンセル") { library.cancelImport() }.keyboardShortcut(.cancelAction)
                        Button("取り込む") { library.confirmImport() }.keyboardShortcut(.defaultAction)
                            .disabled(library.plannedImportCount == 0 || library.items.count + library.plannedImportCount > 1000)
                            .accessibilityIdentifier("confirmImportBookmarksButton")
                    }
                }.padding(20).frame(width: 460)
            }
        }
        .onChange(of: library.items) { _, items in
            if let folder, !items.contains(where: { $0.folders == folder }) { self.folder = nil }
        }
        .onChange(of: selected, initial: true) { _, value in titleDraft = value?.title ?? "" }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = "ブックマークHTMLを選択"
        panel.prompt = "選択"
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let directory = FilePanelDefaults.testDirectory { panel.directoryURL = directory }
        choosingImport = true
        panel.begin { response in
            choosingImport = false
            if response == .OK, let url = panel.url { library.prepareImport(from: url) }
        }
    }

}
