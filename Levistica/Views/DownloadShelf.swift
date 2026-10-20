import SwiftUI

struct DownloadShelf: View {
    @Bindable var manager: DownloadManager

    var body: some View {
        VStack(spacing: 4) {
            if let notice = manager.notice {
                HStack {
                    Text(notice)
                    Button("閉じる") { manager.notice = nil }
                }.padding(8)
            }
            if !manager.items.isEmpty {
                Divider()
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(manager.items) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.filename).lineLimit(1)
                                    Text(item.status).font(.caption)
                                        .accessibilityIdentifier("downloadStatus-\(item.id)")
                                    if item.active && item.destination != nil {
                                        if item.total > 0 {
                                            ProgressView(value: Double(item.received), total: Double(item.total))
                                        } else {
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                }
                                Spacer()
                                if item.active {
                                    Button("取り消す") { manager.cancel(item) }
                                        .accessibilityIdentifier("cancelDownload-\(item.id)")
                                } else if item.completed {
                                    Button("Finderに表示") { manager.showInFinder(item) }
                                } else if item.destination != nil {
                                    Button("一時データを確認") { manager.showInFinder(item) }
                                }
                            }
                        }
                    }.padding(10)
                }.frame(height: min(180, CGFloat(manager.items.count) * 80))
                .accessibilityIdentifier("downloadShelf")
            }
        }
    }
}
