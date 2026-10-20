import SwiftUI

struct PageFindBar: View {
    let session: BrowserSession
    @Bindable var tab: BrowserTab
    @Bindable var page: PageRuntime
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("ページ内を検索", text: $page.findQuery)
                .textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityIdentifier("pageFindField")
                .onSubmit { page.findNext() }
                .onChange(of: page.findQuery) { page.invalidateFindResult() }
            if let found = page.findMatchFound {
                Text(found ? "見つかりました" : "見つかりません")
                    .font(.caption).accessibilityIdentifier("findResult")
            }
            Button("前を検索", systemImage: "chevron.up") { page.findNext(backwards: true) }
                .disabled(page.findQuery.isEmpty).accessibilityIdentifier("findPreviousButton")
            Button("次を検索", systemImage: "chevron.down") { page.findNext() }
                .disabled(page.findQuery.isEmpty).accessibilityIdentifier("findNextButton")
            Button("検索を閉じる", systemImage: "xmark") { close() }
                .accessibilityIdentifier("closeFindButton")
        }
        .labelStyle(.iconOnly).padding(8)
        .onAppear { focused = true }
        .onChange(of: session.findFocusRequest) { focused = true }
        .onExitCommand { close() }
    }

    private func close() {
        page.clearFind()
        tab.isFindBarVisible = false
    }
}
