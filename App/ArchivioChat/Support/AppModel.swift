import SwiftUI
import Observation
import ArchivioCore

/// Un messaggio da raggiungere dentro una conversazione.
struct ChatRoute: Hashable {
    var conversationID: Int64
    var messageID: Int64?
}

/// Lo stato condiviso dell'app: l'archivio e l'elenco delle chat.
@MainActor
@Observable
final class AppModel {
    let store: ArchiveStore?
    let importer: Importer?
    let thumbnails: ThumbnailCache
    let audio = AudioPlayer()
    private(set) var chats: [ChatSummary] = []
    private(set) var startupError: String?
    /// Cambia a ogni modifica dell'archivio: le schermate aperte si aggiornano.
    private(set) var revision = 0

    init() {
        let fm = FileManager.default
        var directory = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Archivio")
        // Per le prove: -archivioDir <percorso> usa un'altra cartella.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-archivioDir"), i + 1 < args.count {
            directory = URL(fileURLWithPath: args[i + 1])
        }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbs")
        do {
            let store = try ArchiveStore(directory: directory)
            // I dati restano sul dispositivo: esclusi anche dai backup su iCloud.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var dir = directory
            try? dir.setResourceValues(values)
            self.store = store
            importer = Importer(store: store)
            thumbnails = ThumbnailCache(media: store.media, directory: caches)
            #if DEBUG
            DemoLaunch.run(store: store, importer: Importer(store: store))
            #endif
        } catch {
            store = nil
            importer = nil
            thumbnails = ThumbnailCache(media: nil, directory: caches)
            startupError = "Impossibile aprire l'archivio: \(error.localizedDescription)"
        }
        reload()
    }

    func reload() {
        guard let store else { return }
        chats = (try? store.chatList()) ?? []
        revision += 1
    }

    func fileURL(for attachment: AttachmentInfo) -> URL? {
        store?.media.url(forHash: attachment.sha256, ext: attachment.ext)
    }

    /// File da far suonare: la copia convertita per i vocali, altrimenti l'originale.
    func playableURL(for attachment: AttachmentInfo) -> URL? {
        guard let store else { return nil }
        if let hash = attachment.playableHash { return store.media.url(forHash: hash, ext: "caf") }
        if ["opus", "ogg"].contains(attachment.ext) { return nil }
        return store.media.url(forHash: attachment.sha256, ext: attachment.ext)
    }

    func avatarURL(_ hash: String?) -> URL? {
        guard let hash, let store else { return nil }
        return store.media.url(forHash: hash, ext: "jpg")
    }

    func toggleStar(_ row: MessageRow) {
        try? store?.setStar(messageID: row.id, !row.starred)
        reload()
    }
}
