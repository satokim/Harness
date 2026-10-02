import Foundation
import SwiftData

/// 사이트별 규칙. `domain` 은 탭이 고정된 사이트의 등록 도메인.
@Model
final class SiteRule {
    @Attribute(.unique) var domain: String
    /// 이 사이트에서 이동을 허용한 다른 사이트.
    var allowedDestinations: [String] = []
    /// nil 이면 전체 설정을 따른다.
    var javaScriptEnabled: Bool?
    var blockThirdPartyScripts: Bool?
    var updatedAt = Date.now

    init(domain: String) {
        self.domain = domain
    }
}

/// 창(세션)별로 열려 있던 탭.
@Model
final class SavedTab {
    var sessionID: String
    var order: Int
    var urlString: String
    var title: String
    var isSelected: Bool
    var updatedAt = Date.now

    init(sessionID: String, order: Int, urlString: String, title: String, isSelected: Bool) {
        self.sessionID = sessionID
        self.order = order
        self.urlString = urlString
        self.title = title
        self.isSelected = isSelected
    }
}

@Model
final class Bookmark {
    @Attribute(.unique) var urlString: String
    var title: String
    var createdAt = Date.now
    /// nil 이면 그룹 없음.
    var folder: BookmarkFolder?

    init(urlString: String, title: String) {
        self.urlString = urlString
        self.title = title
    }
}

/// 북마크 그룹. 그룹을 지워도 안의 북마크는 '그룹 없음' 으로 남는다.
@Model
final class BookmarkFolder {
    var name: String
    var createdAt = Date.now
    @Relationship(deleteRule: .nullify, inverse: \Bookmark.folder) var bookmarks: [Bookmark] = []

    init(name: String) {
        self.name = name
    }
}

@Model
final class HistoryEntry {
    var urlString: String
    var title: String
    var visitedAt = Date.now

    init(urlString: String, title: String) {
        self.urlString = urlString
        self.title = title
    }
}

@Model
final class BlockedRecord {
    var kindRaw: String
    var urlString: String
    /// 차단 당시 탭이 고정돼 있던 사이트.
    var sourceDomain: String?
    var date = Date.now

    var kind: BlockedEvent.Kind? { BlockedEvent.Kind(rawValue: kindRaw) }
    var url: URL? { URL(string: urlString) }

    init(kind: BlockedEvent.Kind, urlString: String, sourceDomain: String?) {
        kindRaw = kind.rawValue
        self.urlString = urlString
        self.sourceDomain = sourceDomain
    }
}

extension BrowserStore {
    static let modelTypes: [any PersistentModel.Type] = [
        SiteRule.self, SavedTab.self, Bookmark.self, BookmarkFolder.self, HistoryEntry.self, BlockedRecord.self,
    ]
}
