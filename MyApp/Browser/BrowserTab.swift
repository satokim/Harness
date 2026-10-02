import Foundation
import WebKit

struct BlockedEvent: Identifiable, Hashable {
    enum Kind: String {
        case popup
        case externalApp
        case crossSite

        var label: String {
            switch self {
            case .popup: "팝업"
            case .externalApp: "외부 앱 호출"
            case .crossSite: "다른 사이트로 이동"
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let url: URL
    let date = Date()

    var label: String { kind.label }

    /// 외부 앱 호출은 앱 안에서 열 수 없으므로 허용 대상에서 뺀다.
    var isAllowable: Bool { kind != .externalApp }
}

@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let contentController = WKUserContentController()
    @ObservationIgnored private let settings: ShieldSettings
    @ObservationIgnored private weak var store: BrowserStore?

    private(set) var title = ""
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    /// 마지막으로 열도록 요청한 주소. 복원된 탭은 선택될 때까지 이 주소만 갖고 있다.
    private(set) var requestedURL: URL?
    @ObservationIgnored private var restoredTitle = ""
    /// 이 탭이 머무를 사이트. 주소창에서 직접 연 사이트로 고정된다.
    private(set) var lockedDomain: String?
    private(set) var siteRule: SiteRule?
    private(set) var blockedEvents: [BlockedEvent] = []
    var bannerEvent: BlockedEvent?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !restoredTitle.isEmpty { return restoredTitle }
        return (currentURL ?? requestedURL)?.host() ?? "새 탭"
    }

    var allowedDomains: [String] { siteRule?.allowedDestinations ?? [] }
    var javaScriptEnabled: Bool { siteRule?.javaScriptEnabled ?? settings.javaScriptEnabled }
    var blocksThirdPartyScripts: Bool { siteRule?.blockThirdPartyScripts ?? settings.blockThirdPartyScripts }

    init(settings: ShieldSettings, store: BrowserStore) {
        self.settings = settings
        self.store = store
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [
            watch(\.title), watch(\.url), watch(\.canGoBack), watch(\.canGoForward),
            watch(\.isLoading), watch(\.estimatedProgress),
        ]
    }

    func load(_ url: URL) {
        requestedURL = url
        lock(to: url.host().map(Self.baseDomain))
        bannerEvent = nil
        webView.load(URLRequest(url: url))
    }

    /// 저장된 탭을 읽어 들이지 않고 주소만 기억해 둔다.
    func restore(url: URL, title: String) {
        requestedURL = url
        restoredTitle = title
    }

    func loadIfNeeded() {
        guard currentURL == nil, !webView.isLoading, let requestedURL else { return }
        load(requestedURL)
    }

    func allow(_ event: BlockedEvent) {
        guard event.isAllowable, let host = event.url.host() else { return }
        if let lockedDomain {
            store?.allowDestination(Self.baseDomain(host), from: lockedDomain)
            reloadSiteRule()
        }
        bannerEvent = nil
        webView.load(URLRequest(url: event.url))
    }

    func clearBlockedEvents() {
        blockedEvents = []
        bannerEvent = nil
    }

    func setSiteJavaScript(_ enabled: Bool?) {
        updateSiteRule { $0.javaScriptEnabled = enabled }
        webView.reload()
    }

    func setSiteThirdPartyScripts(_ blocked: Bool?) {
        updateSiteRule { $0.blockThirdPartyScripts = blocked }
        applyContentRules()
        webView.reload()
    }

    /// 규칙이 바뀌거나 지워졌을 때 다시 읽는다.
    func reloadSiteRule() {
        siteRule = lockedDomain.flatMap { store?.siteRule(for: $0, createIfNeeded: false) }
        applyContentRules()
    }

    func applyContentRules() {
        contentController.removeAllContentRuleLists()
        if blocksThirdPartyScripts, let rules = store?.thirdPartyScriptRules {
            contentController.add(rules)
        }
    }

    private func lock(to domain: String?) {
        lockedDomain = domain
        reloadSiteRule()
    }

    private func updateSiteRule(_ change: (SiteRule) -> Void) {
        guard let lockedDomain, let store, let rule = store.siteRule(for: lockedDomain, createIfNeeded: true) else { return }
        change(rule)
        rule.updatedAt = .now
        store.save()
        siteRule = rule
    }

    private func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) -> NSKeyValueObservation {
        webView.observe(keyPath, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncState() }
        }
    }

    private func syncState() {
        title = webView.title ?? ""
        currentURL = webView.url
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        progress = webView.estimatedProgress
    }

    private func record(_ kind: BlockedEvent.Kind, _ url: URL) {
        let event = BlockedEvent(kind: kind, url: url)
        blockedEvents.insert(event, at: 0)
        bannerEvent = event
        store?.recordBlocked(event, from: lockedDomain)
    }

    private func isSameSite(_ url: URL) -> Bool {
        guard let host = url.host() else { return false }
        let domain = Self.baseDomain(host)
        return domain == lockedDomain || allowedDomains.contains(domain)
    }

    /// 서브도메인을 묶어 비교하기 위한 대략적인 등록 도메인. (`www.example.co.kr` → `example.co.kr`)
    nonisolated static func baseDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevels: Set<Substring> = ["co", "or", "ne", "go", "ac", "re", "com", "net", "org", "edu", "gov"]
        let hasSecondLevel = labels[labels.count - 1].count == 2 && secondLevels.contains(labels[labels.count - 2])
        return labels.suffix(hasSecondLevel ? 3 : 2).joined(separator: ".")
    }
}

// MARK: - 이동 제어

extension BrowserTab: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = policy(for: navigationAction)
        preferences.allowsContentJavaScript = javaScriptEnabled
        return (policy, preferences)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncState()
        if let url = webView.url {
            store?.recordVisit(url: url, title: title)
        }
        store?.persistTabs()
    }

    private func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .cancel }

        switch scheme {
        case "http", "https":
            break
        case "about", "data", "blob":
            return .allow
        default:
            // itms-apps:, intent:, 각종 앱 스킴 → 다른 앱이 열리지 않게 막는다
            record(.externalApp, url)
            return .cancel
        }

        // iframe 안의 이동은 화면을 빼앗지 않으므로 그대로 둔다
        guard action.targetFrame?.isMainFrame ?? true else { return .allow }
        guard settings.siteLockEnabled, action.navigationType != .backForward else { return .allow }

        if lockedDomain == nil, let host = url.host() {
            lock(to: Self.baseDomain(host))
        }
        if isSameSite(url) { return .allow }

        // 서버 리다이렉트 · location 변경 · 광고 오버레이 클릭 모두 여기서 걸린다
        record(.crossSite, url)
        return .cancel
    }
}

// MARK: - 팝업 제어

extension BrowserTab: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        let isWebURL = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        // 같은 사이트의 target=_blank 링크를 직접 누른 경우만 새 탭으로 연다
        if navigationAction.navigationType == .linkActivated, isWebURL, isSameSite(url) {
            store?.newTab(url: url)
        } else {
            record(.popup, url)
        }
        return nil
    }
}
