import SwiftData
import SwiftUI

/// 북마크 · 방문 기록 · 차단 통계 · 사이트 규칙.
struct LibraryView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case bookmarks, history, blocked, sites

        var id: Self { self }

        var title: LocalizedStringKey {
            switch self {
            case .bookmarks: "북마크"
            case .history: "기록"
            case .blocked: "차단"
            case .sites: "사이트"
            }
        }
    }

    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .bookmarks
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("보관함", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding()

                switch section {
                case .bookmarks: BookmarkList(search: searchText, open: open)
                case .history: HistoryList(search: searchText, open: open)
                case .blocked: BlockedStatsList()
                case .sites: SiteRuleList(store: store)
                }
            }
            .searchable(text: $searchText, prompt: "제목 또는 주소")
            .navigationTitle("보관함")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    private func open(_ url: URL, inNewTab: Bool) {
        if inNewTab || store.selectedTab == nil {
            store.newTab(url: url)
        } else {
            store.selectedTab?.load(url)
        }
        dismiss()
    }
}

private struct LinkRow: View {
    let title: String
    let urlString: String
    let date: Date?
    let open: (URL, Bool) -> Void

    var body: some View {
        Button {
            if let url = URL(string: urlString) { open(url, false) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? urlString : title).lineLimit(1)
                HStack {
                    Text(urlString).lineLimit(1)
                    if let date {
                        Spacer()
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("새 탭에서 열기") {
                if let url = URL(string: urlString) { open(url, true) }
            }
        }
    }
}

private struct BookmarkList: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    let search: String
    let open: (URL, Bool) -> Void

    var body: some View {
        let items = bookmarks.filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.urlString.localizedStandardContains(search)
        }
        List {
            ForEach(items) { bookmark in
                LinkRow(title: bookmark.title, urlString: bookmark.urlString, date: nil, open: open)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(items[index]) }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("북마크 없음", systemImage: "star", description: Text("주소창의 별 버튼으로 추가합니다."))
            }
        }
    }
}

private struct HistoryList: View {
    @Environment(\.modelContext) private var context
    @Query private var entries: [HistoryEntry]
    let open: (URL, Bool) -> Void

    init(search: String, open: @escaping (URL, Bool) -> Void) {
        var descriptor = FetchDescriptor<HistoryEntry>(
            predicate: #Predicate {
                search.isEmpty || $0.title.localizedStandardContains(search) || $0.urlString.localizedStandardContains(search)
            },
            sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 300
        _entries = Query(descriptor)
        self.open = open
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                LinkRow(title: entry.title, urlString: entry.urlString, date: entry.visitedAt, open: open)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(entries[index]) }
            }
            if !entries.isEmpty {
                Button("기록 전체 삭제", role: .destructive) {
                    try? context.delete(model: HistoryEntry.self)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("기록 없음", systemImage: "clock")
            }
        }
    }
}

private struct BlockedStatsList: View {
    private struct Stat: Identifiable {
        let host: String
        let count: Int
        let lastDate: Date
        let kinds: [String]
        var id: String { host }
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \BlockedRecord.date, order: .reverse) private var records: [BlockedRecord]

    private var stats: [Stat] {
        Dictionary(grouping: records) { $0.url?.host() ?? $0.urlString }
            .map { host, records in
                Stat(
                    host: host,
                    count: records.count,
                    lastDate: records[0].date,
                    kinds: Array(Set(records.compactMap { $0.kind?.label })).sorted()
                )
            }
            .sorted { $0.count > $1.count }
    }

    var body: some View {
        List {
            Section {
                ForEach(stats) { stat in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.host).lineLimit(1)
                            Text(stat.kinds.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(stat.count)회").monospacedDigit()
                            Text(stat.lastDate, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                if !records.isEmpty { Text("최근 30일 · 차단 횟수 순 (총 \(records.count)건)") }
            }
            if !records.isEmpty {
                Button("차단 기록 지우기", role: .destructive) {
                    try? context.delete(model: BlockedRecord.self)
                }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("차단 기록 없음", systemImage: "shield")
            }
        }
    }
}

private struct SiteRuleList: View {
    let store: BrowserStore
    @Query(sort: \SiteRule.domain) private var rules: [SiteRule]

    var body: some View {
        List {
            ForEach(rules) { rule in
                Section(rule.domain) {
                    LabeledContent("JavaScript", value: label(rule.javaScriptEnabled, on: String(localized: "허용"), off: String(localized: "차단")))
                    LabeledContent("외부 스크립트", value: label(rule.blockThirdPartyScripts, on: String(localized: "차단"), off: String(localized: "허용")))
                    ForEach(rule.allowedDestinations, id: \.self) { destination in
                        HStack {
                            Text("이동 허용 · \(destination)")
                            Spacer()
                            Button {
                                store.removeDestination(destination, from: rule)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("이 사이트 규칙 삭제", role: .destructive) {
                        store.delete(rule)
                    }
                }
            }
        }
        .overlay {
            if rules.isEmpty {
                ContentUnavailableView(
                    "저장된 규칙 없음",
                    systemImage: "globe",
                    description: Text("차단된 이동을 허용하거나, 방패 메뉴에서 사이트별 설정을 바꾸면 여기에 저장됩니다.")
                )
            }
        }
    }

    private func label(_ value: Bool?, on: String, off: String) -> String {
        guard let value else { return String(localized: "전체 설정 따름") }
        return value ? on : off
    }
}
