import SwiftUI

struct BookmarkPanel: View {
    @Bindable var session: BrowserSession
    @Bindable var library: BookmarkLibrary
    @State private var query = ""
    @State private var titleDraft = ""

    private var selected: Bookmark? { library.items.first { $0.id == library.selectedID } }
    private var filtered: [Bookmark] {
        library.items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query) }
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
            if let notice = library.notice {
                Text(notice).font(.caption).accessibilityIdentifier("bookmarkNotice")
                Button("読み込みを再試行") { library.load() }
            }
            List(selection: $library.selectedID) {
                ForEach(filtered) { item in
                    VStack(alignment: .leading) {
                        Text(item.title).lineLimit(1)
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
        .onChange(of: selected, initial: true) { _, value in titleDraft = value?.title ?? "" }
    }
}
