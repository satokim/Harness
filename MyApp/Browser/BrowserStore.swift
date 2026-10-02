import Foundation
import SwiftData
import WebKit

@Observable
final class ShieldSettings {
    private enum Key {
        static let siteLock = "shield.siteLock"
        static let thirdPartyScripts = "shield.blockThirdPartyScripts"
        static let javaScript = "shield.javaScript"
    }

    /// 열린 사이트 밖으로 나가는 이동을 막는다.
    var siteLockEnabled: Bool {
        didSet { UserDefaults.standard.set(siteLockEnabled, forKey: Key.siteLock) }
    }
    /// 다른 도메인에서 불러오는 스크립트(광고 · 추적 · 리다이렉트용)를 막는다.
    var blockThirdPartyScripts: Bool {
        didSet { UserDefaults.standard.set(blockThirdPartyScripts, forKey: Key.thirdPartyScripts) }
    }
    var javaScriptEnabled: Bool {
        didSet { UserDefaults.standard.set(javaScriptEnabled, forKey: Key.javaScript) }
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Key.siteLock: true, Key.thirdPartyScripts: true, Key.javaScript: true])
        siteLockEnabled = defaults.bool(forKey: Key.siteLock)
        blockThirdPartyScripts = defaults.bool(forKey: Key.thirdPartyScripts)
        javaScriptEnabled = defaults.bool(forKey: Key.javaScript)
    }
}

@Observable
final class BrowserStore {
    let settings = ShieldSettings()
    /// 창 하나에 하나. 탭 복원 단위다.
    let sessionID: String
    private(set) var tabs: [BrowserTab] = []
    var selectedTabID: UUID? {
        didSet { persistTabs() }
    }

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private(set) var thirdPartyScriptRules: WKContentRuleList?
    @ObservationIgnored private var isRestoring = false

    /// 지금 열려 있는 창들의 세션. 같은 탭 목록을 두 창이 나눠 갖지 않게 한다.
    private static var activeSessions: Set<String> = []

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID }
    }

    init(context: ModelContext, sessionID preferredSessionID: String?) {
        self.context = context
        sessionID = Self.resolveSession(preferred: preferredSessionID, in: context)
        Self.activeSessions.insert(sessionID)
        pruneOldData()
        restoreTabs()
        if tabs.isEmpty { newTab() }
        Task { await prepareContentRules() }
    }

    func save() {
        try? context.save()
    }

    // MARK: 탭

    @discardableResult
    func newTab(url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(settings: settings, store: self)
        tab.applyContentRules()
        tabs.append(tab)
        selectedTabID = tab.id
        if let url { tab.load(url) }
        persistTabs()
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.webView.stopLoading()
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab()
        } else if selectedTabID == tab.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        persistTabs()
    }

    func persistTabs() {
        guard !isRestoring else { return }
        let sessionID = sessionID
        let saved = (try? context.fetch(FetchDescriptor<SavedTab>(predicate: #Predicate { $0.sessionID == sessionID }))) ?? []
        for tab in saved {
            context.delete(tab)
        }
        for (index, tab) in tabs.enumerated() {
            guard let url = tab.currentURL ?? tab.requestedURL else { continue }
            context.insert(SavedTab(
                sessionID: sessionID,
                order: index,
                urlString: url.absoluteString,
                title: tab.displayTitle,
                isSelected: tab.id == selectedTabID
            ))
        }
        save()
    }

    private func restoreTabs() {
        isRestoring = true
        defer { isRestoring = false }

        let sessionID = sessionID
        let descriptor = FetchDescriptor<SavedTab>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.order)]
        )
        for saved in (try? context.fetch(descriptor)) ?? [] {
            guard let url = URL(string: saved.urlString) else { continue }
            let tab = BrowserTab(settings: settings, store: self)
            tab.restore(url: url, title: saved.title)
            tabs.append(tab)
            if saved.isSelected { selectedTabID = tab.id }
        }
        if selectedTabID == nil { selectedTabID = tabs.first?.id }
    }

    /// 창에 남아 있던 세션을 이어받는다. 없으면(iPhone 에서 강제 종료 등) 가장 최근 세션을 이어받는다.
    private static func resolveSession(preferred: String?, in context: ModelContext) -> String {
        if let preferred, !activeSessions.contains(preferred) { return preferred }
        let descriptor = FetchDescriptor<SavedTab>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let saved = (try? context.fetch(descriptor)) ?? []
        if let latest = saved.first(where: { !activeSessions.contains($0.sessionID) }) {
            return latest.sessionID
        }
        return UUID().uuidString
    }

    // MARK: 사이트 규칙

    func siteRule(for domain: String, createIfNeeded: Bool) -> SiteRule? {
        let descriptor = FetchDescriptor<SiteRule>(predicate: #Predicate { $0.domain == domain })
        if let rule = try? context.fetch(descriptor).first { return rule }
        guard createIfNeeded else { return nil }
        let rule = SiteRule(domain: domain)
        context.insert(rule)
        return rule
    }

    func allowDestination(_ destination: String, from domain: String) {
        guard let rule = siteRule(for: domain, createIfNeeded: true) else { return }
        if !rule.allowedDestinations.contains(destination) {
            rule.allowedDestinations.append(destination)
        }
        rule.updatedAt = .now
        save()
    }

    func removeDestination(_ destination: String, from rule: SiteRule) {
        rule.allowedDestinations.removeAll { $0 == destination }
        rule.updatedAt = .now
        save()
        refreshTabs(lockedTo: rule.domain)
    }

    func delete(_ rule: SiteRule) {
        let domain = rule.domain
        context.delete(rule)
        save()
        refreshTabs(lockedTo: domain)
    }

    private func refreshTabs(lockedTo domain: String) {
        for tab in tabs where tab.lockedDomain == domain {
            tab.reloadSiteRule()
        }
    }

    // MARK: 기록 · 북마크

    func recordVisit(url: URL, title: String) {
        var descriptor = FetchDescriptor<HistoryEntry>(sortBy: [SortDescriptor(\.visitedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let last = try? context.fetch(descriptor).first, last.urlString == url.absoluteString {
            last.title = title
            last.visitedAt = .now
        } else {
            context.insert(HistoryEntry(urlString: url.absoluteString, title: title))
        }
        save()
    }

    func recordBlocked(_ event: BlockedEvent, from domain: String?) {
        context.insert(BlockedRecord(kind: event.kind, urlString: event.url.absoluteString, sourceDomain: domain))
        save()
    }

    func toggleBookmark(url: URL, title: String) {
        let urlString = url.absoluteString
        let descriptor = FetchDescriptor<Bookmark>(predicate: #Predicate { $0.urlString == urlString })
        if let bookmark = try? context.fetch(descriptor).first {
            context.delete(bookmark)
        } else {
            context.insert(Bookmark(urlString: urlString, title: title))
        }
        save()
    }

    private func pruneOldData() {
        let day: TimeInterval = 24 * 60 * 60
        let tabCutoff = Date.now.addingTimeInterval(-30 * day)
        let historyCutoff = Date.now.addingTimeInterval(-90 * day)
        let blockedCutoff = Date.now.addingTimeInterval(-30 * day)
        try? context.delete(model: SavedTab.self, where: #Predicate { $0.updatedAt < tabCutoff })
        try? context.delete(model: HistoryEntry.self, where: #Predicate { $0.visitedAt < historyCutoff })
        try? context.delete(model: BlockedRecord.self, where: #Predicate { $0.date < blockedCutoff })
        save()
    }

    // MARK: 콘텐츠 차단 규칙

    func applyContentRules() {
        for tab in tabs {
            tab.applyContentRules()
        }
    }

    private func prepareContentRules() async {
        thirdPartyScriptRules = try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "third-party-scripts",
            encodedContentRuleList: Self.thirdPartyScriptRuleJSON
        )
        applyContentRules()
    }

    private static let thirdPartyScriptRuleJSON = """
    [
      {"trigger": {"url-filter": ".*", "resource-type": ["script"], "load-type": ["third-party"]},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": ".*", "resource-type": ["popup"], "load-type": ["third-party"]},
       "action": {"type": "block"}}
    ]
    """
}

enum URLInput {
    /// 주소창 입력을 URL 로 바꾼다. 주소가 아니면 검색어로 취급한다.
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed) {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }
}
