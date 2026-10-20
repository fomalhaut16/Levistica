import SwiftUI

struct BrowserRootView: View {
    @Bindable var session: BrowserSession
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("戻る", systemImage: "chevron.left") { session.page?.back() }
                    .disabled(session.page?.canGoBack != true).accessibilityIdentifier("backButton")
                Button("進む", systemImage: "chevron.right") { session.page?.forward() }
                    .disabled(session.page?.canGoForward != true).accessibilityIdentifier("forwardButton")
                TextField("URLまたは検索語を入力", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .accessibilityIdentifier("addressField")
                    .onSubmit {
                        if session.navigate(address) { addressFocused = false }
                    }
                if session.page?.isLoading == true {
                    Button("停止", systemImage: "xmark") { session.page?.stop() }
                        .accessibilityIdentifier("stopButton")
                } else {
                    Button("再読み込み", systemImage: "arrow.clockwise") { session.page?.reload() }
                        .disabled(session.page == nil).accessibilityIdentifier("reloadButton")
                }
            }
            .labelStyle(.iconOnly)
            .padding(10)

            if let message = session.inputError ?? session.page?.failure {
                HStack {
                    Text(message).textSelection(.enabled).accessibilityIdentifier("errorMessage")
                    Spacer()
                    if session.inputError == nil && session.page?.canRetry == true {
                        Button("再試行") { session.page?.retry() }
                    }
                    Button("閉じる") {
                        session.inputError = nil
                        session.page?.dismissFailure()
                    }
                }
                .padding(10).background(.regularMaterial)
            }
            Divider()
            if let page = session.page {
                WebPageView(page: page).accessibilityIdentifier("pageView")
                    .overlay(alignment: .top) {
                        if page.isLoading {
                            ProgressView(value: page.progress).progressViewStyle(.linear)
                        }
                    }
            } else {
                ContentUnavailableView("Levistica", systemImage: "globe",
                                       description: Text("URLを入力してページを開きます。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { addressFocused = true }
        .onChange(of: session.addressFocusRequest) { addressFocused = true }
        .onChange(of: session.page?.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused, session.inputError == nil { address = session.page?.url?.absoluteString ?? address }
        }
    }
}
