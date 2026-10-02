import SwiftData
import SwiftUI

/// 주소창 별 버튼에서 여는 북마크 추가 · 편집 화면.
struct BookmarkEditorView: View {
    let store: BrowserStore
    let url: URL
    let defaultTitle: String

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookmarkFolder.name) private var folders: [BookmarkFolder]
    @State private var title = ""
    @State private var folder: BookmarkFolder?
    @State private var newFolderName = ""
    @State private var isExisting = false

    var body: some View {
        Form {
            Section {
                TextField("제목", text: $title)
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Section("그룹") {
                Picker("그룹", selection: $folder) {
                    Text("그룹 없음").tag(BookmarkFolder?.none)
                    ForEach(folders) { folder in
                        Text(folder.name).tag(BookmarkFolder?.some(folder))
                    }
                }
                HStack {
                    TextField("새 그룹 이름", text: $newFolderName)
                        .onSubmit(createFolder)
                    Button("추가", action: createFolder)
                        .disabled(trimmedFolderName.isEmpty)
                }
            }

            Section {
                Button("저장") {
                    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.saveBookmark(url: url, title: title.isEmpty ? defaultTitle : title, folder: folder)
                    dismiss()
                }
                if isExisting {
                    Button("북마크 삭제", role: .destructive) {
                        if let bookmark = store.bookmark(for: url) { store.delete(bookmark) }
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 320, minHeight: 380)
        .onAppear {
            let bookmark = store.bookmark(for: url)
            isExisting = bookmark != nil
            title = bookmark?.title ?? defaultTitle
            folder = bookmark?.folder
        }
    }

    private var trimmedFolderName: String {
        newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createFolder() {
        guard !trimmedFolderName.isEmpty else { return }
        folder = store.createFolder(named: trimmedFolderName)
        newFolderName = ""
    }
}
