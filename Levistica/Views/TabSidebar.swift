import SwiftUI

struct TabSidebar: View {
    @Bindable var session: BrowserSession
    var didSelectTab: (() -> Void)? = nil
    @State private var filter = ""

    private var visibleTabs: [BrowserTab] {
        guard !filter.isEmpty else { return session.tabs }
        return session.tabs.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(filter) ||
            (($0.page?.url ?? $0.pendingURL)?.absoluteString.localizedCaseInsensitiveContains(filter) == true)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("タブ").font(.headline)
                Spacer()
                Button("新しいタブ", systemImage: "plus") {
                    if session.newTab() != nil { didSelectTab?() }
                }
                    .labelStyle(.iconOnly).accessibilityIdentifier("newTabButton")
            }.padding([.horizontal, .top], 10)
            TextField("タブを検索", text: $filter)
                .textFieldStyle(.roundedBorder).padding(.horizontal, 10)
                .accessibilityIdentifier("tabSearchField")
            ScrollViewReader { proxy in
                List(selection: Binding<UUID?>(
                    get: { session.selectedID },
                    set: {
                        if let id = $0 {
                            // A deferred page's title can change as soon as it loads.
                            // Finish the search before selecting so its row stays available.
                            filter = ""
                            session.select(id)
                            didSelectTab?()
                        }
                    }
                )) {
                    ForEach(visibleTabs) { tab in
                        HStack {
                            Image(systemName: tab.isKept ? "pin.fill" : (tab.isSleeping ? "moon.zzz" : (tab.page == nil ? "doc" : "globe")))
                                .accessibilityLabel(tab.isKept ? "保持するタブ" : (tab.isSleeping ? "休眠中" : "ページ"))
                            Text(tab.displayTitle).lineLimit(1)
                            if tab.page?.inputGuard.hasEditedInput == true {
                                Image(systemName: "pencil").accessibilityLabel("入力操作あり")
                                    .help("入力操作を検知したタブです。閉じるときに確認します。")
                                    .accessibilityIdentifier("editedInput-\(tab.id)")
                            }
                            Spacer(minLength: 0)
                            Button("タブを閉じる", systemImage: "xmark") { session.closeTab(tab.id) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .accessibilityIdentifier("closeTab-\(tab.id)")
                        }
                        .tag(tab.id)
                        .id(tab.id)
                        .accessibilityIdentifier("tab-\(tab.id)")
                        .contextMenu {
                            TabContextMenu(session: session, tab: tab)
                        }
                        .moveDisabled(!filter.isEmpty)
                    }
                    .onMove { source, destination in
                        guard filter.isEmpty else { return }
                        session.moveTabs(from: source, to: destination)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("tabList")
                .task(id: filter.isEmpty ? session.selectedID : nil) {
                    guard filter.isEmpty else { return }
                    // Let the restored/filtered list lay out before locating its row.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(session.selectedID, anchor: .center)
                }
            }
            Text("\(session.tabs.count)タブ・読み込み済み\(session.loadedPageCount)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 8).accessibilityIdentifier("tabLoadSummary")
        }
        .onChange(of: session.selectedID) {
            if !visibleTabs.contains(where: { $0.id == session.selectedID }) { filter = "" }
        }
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
        #if LEVISTICA_MEASUREMENT
        .overlay(alignment: .bottomLeading) {
            if MeasurementViewportStatus.enabled {
                MeasurementViewportStatus(page: session.page)
                    .background(.regularMaterial)
            }
        }
        #endif
    }
}


private struct TabContextMenu: View {
    let session: BrowserSession
    let tab: BrowserTab

    var body: some View {
        Button(tab.isKept ? "タブの保持を解除" : "このタブを保持") { session.toggleKeep(tab.id) }
        if tab.id == session.selectedID {
            Button("このタブを休眠…") { session.requestSelectedTabSleep() }
                .disabled(tab.page == nil || session.isRequestingSleep)
        }
        Divider()
        Button("タブを閉じる") { session.closeTab(tab.id) }
        Divider()
        Button("前に移動") { session.moveTab(tab.id, by: -1) }
            .disabled(session.tabs.first?.id == tab.id)
        Button("後ろに移動") { session.moveTab(tab.id, by: 1) }
            .disabled(session.tabs.last?.id == tab.id)
    }
}

struct HorizontalTabBar: View {
    @Bindable var session: BrowserSession
    @State private var showingList = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 4) {
                        ForEach(session.tabs) { tab in
                            HStack(spacing: 4) {
                                Button { session.select(tab.id) } label: {
                                    Label(tab.displayTitle,
                                          systemImage: tab.isKept ? "pin.fill" : (tab.isSleeping ? "moon.zzz" : "globe"))
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("tab-\(tab.id)")
                                .help(tab.displayTitle)
                                .accessibilityAddTraits(tab.id == session.selectedID ? [.isSelected] : [])
                                if tab.page?.inputGuard.hasEditedInput == true {
                                    Image(systemName: "pencil").accessibilityLabel("入力操作あり")
                                }
                                Button("タブを閉じる", systemImage: "xmark") { session.closeTab(tab.id) }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                    .accessibilityIdentifier("closeTab-\(tab.id)")
                            }
                            .padding(8).frame(width: 184)
                            .background(tab.id == session.selectedID ? Color.accentColor.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .id(tab.id)
                            .contextMenu { TabContextMenu(session: session, tab: tab) }
                        }
                    }
                }
                .accessibilityIdentifier("horizontalTabList")
                .task(id: session.selectedID) {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(session.selectedID, anchor: .center)
                }
            }
            Button("新しいタブ", systemImage: "plus") { _ = session.newTab() }
                .labelStyle(.iconOnly).accessibilityIdentifier("newTabButton")
            Button("タブ一覧", systemImage: "list.bullet") { showingList.toggle() }
                .labelStyle(.iconOnly).accessibilityIdentifier("showTabListButton")
                .popover(isPresented: $showingList) {
                    TabSidebar(session: session, didSelectTab: { showingList = false })
                        .frame(width: 280, height: 420)
                }
            Text("\(session.tabs.count)タブ・読み込み済み\(session.loadedPageCount)")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("tabLoadSummary")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(height: 58)
    }
}
