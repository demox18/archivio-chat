#if DEBUG
import Foundation
import UIKit
import ArchivioCore

/// Comandi di avvio per le prove nel simulatore (solo build di debug):
///   -demoImport "<file>|<file>"   importa i file indicati, senza interfaccia
///   -demoOpen chat|info|gallery|search|starred|settings
///   -demoFind "<testo>"           apre la chat sul primo messaggio che contiene il testo
///   -demoStar "<testo>"           mette la stella ai messaggi che contengono il testo
enum DemoLaunch {
    private static func value(_ key: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var open: String? { value("-demoOpen") }
    /// -demoImportUI <file>: apre la schermata di importazione su quel file.
    static var importUI: URL? { value("-demoImportUI").map { URL(fileURLWithPath: $0) } }
    /// -demoImportAuto: preme "Analizza" da solo appena possibile.
    static var importInto: Bool { ProcessInfo.processInfo.arguments.contains("-demoInto") }
    static var importAuto: Bool { ProcessInfo.processInfo.arguments.contains("-demoImportAuto") }

    /// -demoSnapshot <file.png>: dopo qualche secondo l'app salva un'immagine
    /// della propria finestra e si chiude. -demoDark usa il tema scuro.
    @MainActor
    static func scheduleSnapshot() {
        guard let path = value("-demoSnapshot") else { return }
        let delay = Double(value("-demoDelay") ?? "") ?? 4
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            let size = CGSize(width: 402, height: 874)
            scene.sizeRestrictions?.minimumSize = size
            scene.sizeRestrictions?.maximumSize = size
            if ProcessInfo.processInfo.arguments.contains("-demoDark") {
                scene.windows.forEach { $0.overrideUserInterfaceStyle = .dark }
            }
            if ProcessInfo.processInfo.arguments.contains("-demoLight") {
                scene.windows.forEach { $0.overrideUserInterfaceStyle = .light }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.flatMap(\.windows).first else { exit(2) }
            // Il visualizzatore a schermo intero vive in una finestra presentata sopra.
            let top = scenes.flatMap(\.windows).last ?? window
            // Un pannello presentato (ricerca, importazione) si fotografa direttamente.
            var controller = top.rootViewController
            var presented = false
            while let next = controller?.presentedViewController { controller = next; presented = true }
            let target: UIView = presented ? (controller?.view ?? top) : top
            let image = UIGraphicsImageRenderer(bounds: target.bounds).image { _ in
                target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
            }
            try? image.pngData()?.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
    static var find: String? { value("-demoFind") }
    private static let myNames: Set<String> = ["Io", "Demy", "demy", "demox18"]

    static func run(store: ArchiveStore, importer: Importer) {
        for path in (value("-demoImport") ?? "").split(separator: "|").map(String.init) {
            let url = URL(fileURLWithPath: path)
            do {
                let t0 = Date()
                let source: any ImportSource = url.pathExtension == "zip" ? try ZipSource(url: url) : TextFileSource(url: url)
                let s = try importer.suggest(source)
                var target = ImportTarget.newConversation(title: s.suggestedTitle, me: s.likelyMe ?? s.senders.first(where: myNames.contains))
                if let id = s.matchedConversationID ?? forcedConversation(store) {
                    let info = try store.conversationInfo(id: id)
                    let known = Set(info.participants.flatMap(\.aliases))
                    var map: [String: ParticipantChoice] = [:]
                    for name in s.senders where !known.contains(name) {
                        let mine = myNames.contains(name)
                        if let p = info.participants.first(where: { $0.isMe == mine }) { map[name] = .existing(p.id) }
                    }
                    target = .existing(conversationID: id, senders: map)
                }
                let plan = try importer.analyze(source, target: target)
                let t1 = Date()
                try importer.apply(plan)
                let s2 = plan.summary
                print("DEMO import \(url.lastPathComponent): file=\(s2.totalInFile) presenti=\(s2.alreadyPresent) nuovi=\(s2.newMessages) doppioni=\(s2.possibleDuplicates) foto=\(s2.photos) video=\(s2.videos) sticker=\(s2.stickers) audio=\(s2.audios) doc=\(s2.documents) collegati=\(s2.attachmentsToLink) mancanti=\(s2.missingAttachments) sovrapposizione=\(s2.overlaps) analisi=\(String(format: "%.1f", t1.timeIntervalSince(t0)))s scrittura=\(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
            } catch {
                print("DEMO import \(url.lastPathComponent) ERRORE: \(error)")
            }
        }
        if let text = value("-demoStar") {
            for hit in (try? store.search(SearchFilter(text: text), limit: 3)) ?? [] { try? store.setStar(messageID: hit.message.id, true) }
        }
        if let st = try? store.stats() { print("DEMO stats chat=\(st.conversations) messaggi=\(st.messages) allegati=\(st.attachments)") }
    }

    /// -demoInto 1: unisce comunque alla prima chat (per provare l'abbinamento dei nomi).
    private static func forcedConversation(_ store: ArchiveStore) -> Int64? {
        guard value("-demoInto") != nil else { return nil }
        return try? store.chatList().first?.id
    }

    static func route(store: ArchiveStore?) -> ChatRoute? {
        guard let store, let open, ["chat", "info", "gallery", "search"].contains(open),
              let chat = try? store.chatList().first else { return nil }
        var messageID: Int64?
        if let find { messageID = (try? store.search(SearchFilter(text: find, conversationID: chat.id), limit: 1))?.first?.message.id }
        if let kind = value("-demoKind"), let section = MediaSection(rawValue: kind) {
            let all = (try? store.mediaItems(conversationID: chat.id, section: section, limit: 40, offset: 0)) ?? []
            messageID = all.dropFirst(all.count / 2).first?.id
        }
        return ChatRoute(conversationID: chat.id, messageID: messageID)
    }
}
#endif
