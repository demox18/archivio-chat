import SwiftUI
import ArchivioCore

@main
struct ArchivioChatApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Int = {
        #if DEBUG
        if DemoLaunch.open == "starred" { return 1 }
        if DemoLaunch.open == "settings" { return 2 }
        #endif
        return 0
    }()

    var body: some View {
        if let error = model.startupError {
            ContentUnavailableView("Archivio non disponibile", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            TabView(selection: $tab) {
                ChatListView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }.tag(0)
                StarredView()
                    .tabItem { Label("Preferiti", systemImage: "star.fill") }.tag(1)
                SettingsView()
                    .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }.tag(2)
            }
            #if DEBUG
            .onAppear { DemoLaunch.scheduleSnapshot() }
            #endif
        }
    }
}
