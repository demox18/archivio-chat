import SwiftUI
import ArchivioCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var stats: ArchiveStats?
    @State private var archiveBytes: Int64?
    @State private var cacheBytes: Int64?

    var body: some View {
        NavigationStack {
            List {
                Section("Archivio") {
                    LabeledContent("Chat", value: (stats?.conversations ?? 0).formatted())
                    LabeledContent("Messaggi", value: (stats?.messages ?? 0).formatted())
                    LabeledContent("Allegati", value: (stats?.attachments ?? 0).formatted())
                    LabeledContent("Spazio occupato", value: archiveBytes.map(bytes) ?? "…")
                }
                Section {
                    LabeledContent("Miniature", value: cacheBytes.map(bytes) ?? "…")
                    Button("Svuota cache miniature") {
                        model.thumbnails.clearDisk()
                        measure()
                    }
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Le miniature si ricreano da sole quando servono. Messaggi e allegati non vengono toccati.")
                }
                Section {
                    Label("Tutti i dati restano su questo iPhone.", systemImage: "lock.fill")
                    Label("L'app non si collega a internet e non invia nulla a nessun servizio.", systemImage: "wifi.slash")
                    Label("I file che importi vengono solo letti: gli originali non sono mai modificati.", systemImage: "doc.badge.gearshape")
                    Label("Questa non è un'app di messaggistica: non invia e non riceve messaggi.", systemImage: "archivebox")
                } header: {
                    Text("Privacy")
                }
                .font(.subheadline)
            }
            .navigationTitle("Impostazioni")
            .task(id: model.revision) { measure() }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func measure() {
        stats = try? model.store?.stats()
        let store = model.store, thumbs = model.thumbnails
        Task {
            let (a, c) = await Task.detached(priority: .utility) { (store?.diskUsage() ?? 0, thumbs.diskUsage()) }.value
            archiveBytes = a
            cacheBytes = c
        }
    }
}
