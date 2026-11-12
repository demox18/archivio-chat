#if DEBUG
import Foundation
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
        return ChatRoute(conversationID: chat.id, messageID: messageID)
    }
}
#endif
