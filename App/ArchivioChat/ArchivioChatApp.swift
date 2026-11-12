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

    var body: some View {
        if let error = model.startupError {
            ContentUnavailableView("Archivio non disponibile", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            TabView {
                ChatListView()
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                StarredView()
                    .tabItem { Label("Preferiti", systemImage: "star.fill") }
                SettingsView()
                    .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
            }
        }
    }
}
