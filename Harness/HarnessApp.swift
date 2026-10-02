import SwiftData
import SwiftUI

@main struct HarnessApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: BrowserStore.modelTypes)
    }
}
