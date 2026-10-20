import SwiftUI

struct TabSidebar: View {
    @Bindable var session: BrowserSession
    @State private var filter = ""

    private var visibleTabs: [BrowserTab] {
        guard !filter.isEmpty else { return session.tabs }
        return session.tabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(filter) ||
            ($0.page?.url?.absoluteString.localizedCaseInsensitiveContains(filter) == true)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("タブ").font(.headline)
                Spacer()
                Button("新しいタブ", systemImage: "plus") { _ = session.newTab() }
                    .labelStyle(.iconOnly).accessibilityIdentifier("newTabButton")
            }.padding([.horizontal, .top], 10)
            TextField("タブを検索", text: $filter)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                .accessibilityIdentifier("tabSearchField")
            List(selection: Binding<UUID?>(
                get: { session.selectedID },
                set: { if let id = $0 { session.select(id) } }
            )) {
                ForEach(visibleTabs) { tab in
                    HStack {
                        Image(systemName: tab.page == nil ? "doc" : "globe")
                        Text(tab.displayTitle).lineLimit(1)
                        Spacer(minLength: 0)
                        Button("タブを閉じる", systemImage: "xmark") { session.closeTab(tab.id) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .accessibilityIdentifier("closeTab-\(tab.id)")
                    }
                    .tag(tab.id)
                    .accessibilityIdentifier("tab-\(tab.id)")
                    .contextMenu {
                        Button("タブを閉じる") { session.closeTab(tab.id) }
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("tabList")
        }
        .onChange(of: session.selectedID) {
            if !visibleTabs.contains(where: { $0.id == session.selectedID }) { filter = "" }
        }
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
    }
}
