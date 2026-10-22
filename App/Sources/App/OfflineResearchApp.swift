import SwiftUI

@main
struct OfflineResearchApp: App {
    init() {
        OfflineGuard.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
