import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    /// 창마다 탭 목록을 따로 복원하기 위한 키.
    @SceneStorage("browserSessionID") private var sessionID = ""
    @State private var store: BrowserStore?

    var body: some View {
        Group {
            if let store {
                BrowserRootView(store: store)
            } else {
                Color.clear
            }
        }
        .task {
            guard store == nil else { return }
            let store = BrowserStore(context: modelContext, sessionID: sessionID.isEmpty ? nil : sessionID)
            sessionID = store.sessionID
            self.store = store
        }
    }
}

private struct BrowserRootView: View {
    let store: BrowserStore
    @State private var showsLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(store: store) { showsLibrary = true }
            if let tab = store.selectedTab {
                BrowserPane(tab: tab, store: store)
                    .id(tab.id)
            }
        }
        .sheet(isPresented: $showsLibrary) {
            LibraryView(store: store)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: BrowserStore.modelTypes, inMemory: true)
}
