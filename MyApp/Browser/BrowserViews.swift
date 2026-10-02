import SwiftData
import SwiftUI
import WebKit

// MARK: - 웹뷰

#if os(macOS)
struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#else
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

// MARK: - 탭 줄

struct TabStripView: View {
    let store: BrowserStore
    let onShowOverview: () -> Void
    let onShowLibrary: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            onSelect: { store.selectedTabID = tab.id },
                            onClose: { store.close(tab) }
                        )
                    }
                }
                .padding(.horizontal)
            }
            Button(action: onShowOverview) {
                Image(systemName: "square.on.square")
            }
            .buttonStyle(.borderless)
            Button(action: onShowLibrary) {
                Image(systemName: "books.vertical")
            }
            .buttonStyle(.borderless)
            Button { store.newTab() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .padding(.trailing)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct TabChip: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.displayTitle)
                .font(.footnote)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2.bold())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - 탭 본문

struct BrowserPane: View {
    let tab: BrowserTab
    let store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            AddressBarView(tab: tab, store: store)
            ProgressView(value: tab.progress)
                .progressViewStyle(.linear)
                .opacity(tab.isLoading ? 1 : 0)
            ZStack(alignment: .bottom) {
                WebViewContainer(webView: tab.webView)
                if tab.currentURL == nil && tab.requestedURL == nil {
                    StartPageView()
                }
                if let event = tab.bannerEvent {
                    BlockedBanner(event: event, tab: tab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: tab.bannerEvent)
        }
        .onAppear { tab.loadIfNeeded() }
    }
}

private struct AddressBarView: View {
    let tab: BrowserTab
    let store: BrowserStore
    @State private var text = ""
    @State private var showsShield = false
    @FocusState private var isEditing: Bool
    @Query private var bookmarks: [Bookmark]

    private var isBookmarked: Bool {
        guard let url = tab.currentURL?.absoluteString else { return false }
        return bookmarks.contains { $0.urlString == url }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack)
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward)

            TextField("주소 입력 또는 검색", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isEditing)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.webSearch)
                #endif
                .onSubmit {
                    guard let url = URLInput.url(from: text) else { return }
                    tab.load(url)
                    isEditing = false
                }

            if tab.isLoading {
                Button { tab.webView.stopLoading() } label: { Image(systemName: "xmark") }
            } else {
                Button { tab.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(tab.currentURL == nil)
            }

            Button {
                if let url = tab.currentURL { store.toggleBookmark(url: url, title: tab.displayTitle) }
            } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
            }
            .disabled(tab.currentURL == nil)

            Button { showsShield = true } label: {
                Image(systemName: "shield.lefthalf.filled")
                    .overlay(alignment: .topTrailing) {
                        if !tab.blockedEvents.isEmpty {
                            Text("\(tab.blockedEvents.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .background(.red, in: .capsule)
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .popover(isPresented: $showsShield) {
                ShieldPanelView(tab: tab, store: store, settings: store.settings)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onAppear { text = tab.currentURL?.absoluteString ?? "" }
        .onChange(of: tab.currentURL) { _, url in
            if !isEditing { text = url?.absoluteString ?? "" }
        }
    }
}

private struct StartPageView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Harness").font(.title.bold())
            Text("주소창에 주소를 입력하세요.\n열린 사이트 밖으로의 이동 · 팝업 · 외부 앱 호출은 자동으로 차단됩니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct BlockedBanner: View {
    let event: BlockedEvent
    let tab: BrowserTab

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(event.label) 차단됨").font(.subheadline.bold())
                Text(event.url.host() ?? event.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if event.isAllowable {
                Button("허용") { tab.allow(event) }
            }
            Button { tab.bannerEvent = nil } label: { Image(systemName: "xmark") }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .padding()
        .task(id: event.id) {
            try? await Task.sleep(for: .seconds(4))
            if tab.bannerEvent?.id == event.id { tab.bannerEvent = nil }
        }
    }
}

// MARK: - 보호 설정 · 차단 기록

private struct ShieldPanelView: View {
    let tab: BrowserTab
    let store: BrowserStore
    @Bindable var settings: ShieldSettings

    var body: some View {
        Form {
            Section {
                Toggle("다른 사이트로 이동 차단", isOn: $settings.siteLockEnabled)
                Toggle("외부 스크립트 차단", isOn: $settings.blockThirdPartyScripts)
                Toggle("JavaScript 허용", isOn: $settings.javaScriptEnabled)
            } header: {
                Text("보호 설정")
            } footer: {
                Text("팝업과 외부 앱 호출은 항상 차단됩니다. 스크립트 설정은 페이지를 다시 불러오면 적용됩니다.")
            }

            if let domain = tab.lockedDomain {
                Section {
                    Picker("JavaScript", selection: Binding(
                        get: { tab.siteRule?.javaScriptEnabled },
                        set: { tab.setSiteJavaScript($0) }
                    )) {
                        Text("전체 설정 따름").tag(Bool?.none)
                        Text("허용").tag(Bool?.some(true))
                        Text("차단").tag(Bool?.some(false))
                    }
                    Picker("외부 스크립트", selection: Binding(
                        get: { tab.siteRule?.blockThirdPartyScripts },
                        set: { tab.setSiteThirdPartyScripts($0) }
                    )) {
                        Text("전체 설정 따름").tag(Bool?.none)
                        Text("차단").tag(Bool?.some(true))
                        Text("허용").tag(Bool?.some(false))
                    }
                    ForEach(tab.allowedDomains.sorted(), id: \.self) { destination in
                        LabeledContent("이동 허용", value: destination)
                    }
                } header: {
                    Text("이 사이트 (\(domain))")
                } footer: {
                    Text("사이트별 설정과 허용한 이동은 저장되어 다음에도 적용됩니다. 보관함 › 사이트에서 관리합니다.")
                }
            }

            Section {
                if tab.blockedEvents.isEmpty {
                    Text("차단 기록 없음").foregroundStyle(.secondary)
                }
                ForEach(tab.blockedEvents) { event in
                    BlockedEventRow(event: event, tab: tab, store: store)
                }
            } header: {
                HStack {
                    Text("차단 기록 (\(tab.blockedEvents.count))")
                    Spacer()
                    if !tab.blockedEvents.isEmpty {
                        Button("지우기") { tab.clearBlockedEvents() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 340, minHeight: 460)
        .onChange(of: settings.blockThirdPartyScripts) {
            store.applyContentRules()
            tab.webView.reload()
        }
        .onChange(of: settings.javaScriptEnabled) {
            tab.webView.reload()
        }
    }
}

private struct BlockedEventRow: View {
    let event: BlockedEvent
    let tab: BrowserTab
    let store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(event.label).font(.caption.bold())
                Spacer()
                Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            if event.isAllowable {
                HStack(spacing: 16) {
                    Button("이 탭에서 열기") { tab.allow(event) }
                    Button("새 탭에서 열기") { store.newTab(url: event.url) }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
    }
}
