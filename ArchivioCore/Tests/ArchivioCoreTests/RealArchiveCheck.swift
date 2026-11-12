import XCTest
import GRDB
@testable import ArchivioCore

/// Verifica locale sui due ZIP veri: gira solo se ARCHIVIO_REAL_ZIPS contiene
/// "primo.zip|secondo.zip". Stampa soltanto numeri e tempi, mai il contenuto.
/// L'archivio di prova viene creato in una cartella temporanea e cancellato alla fine.
final class RealArchiveCheck: XCTestCase {
    func testMergeRealExports() throws {
        guard let raw = ProcessInfo.processInfo.environment["ARCHIVIO_REAL_ZIPS"] else { throw XCTSkip("nessun file vero indicato") }
        let paths = raw.split(separator: "|").map(String.init)
        XCTAssertEqual(paths.count, 2)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("archivio-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ArchiveStore(directory: dir)
        let importer = Importer(store: store)

        func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let t = Date()
            let r = try body()
            print("REALZIP tempo \(label): \(String(format: "%.2f", Date().timeIntervalSince(t)))s")
            return r
        }
        func show(_ label: String, _ s: ImportSummary) {
            print("REALZIP \(label): file=\(s.totalInFile) presenti=\(s.alreadyPresent) nuovi=\(s.newMessages) doppioni=\(s.possibleDuplicates) foto=\(s.photos) video=\(s.videos) sticker=\(s.stickers) audio=\(s.audios) doc=\(s.documents) collegati=\(s.attachmentsToLink) mancanti=\(s.missingAttachments) sovrapposizione=\(s.overlaps) nonRiconosciute=\(s.unrecognizedLines)")
        }

        // 1. Primo file, chat nuova.
        let first = try timed("apertura zip 1") { try ZipSource(url: URL(fileURLWithPath: paths[0])) }
        let sug1 = try timed("proposta 1") { try importer.suggest(first) }
        XCTAssertEqual(sug1.senders.count, 2)
        let me1 = sug1.senders.first { $0.lowercased().hasPrefix("dem") }
        let plan1 = try timed("analisi 1") { try importer.analyze(first, target: .newConversation(title: "Prova", me: me1)) }
        show("primo", plan1.summary)
        try timed("scrittura 1") { _ = try importer.apply(plan1) }
        let conv = try store.chatList()[0].id
        let info1 = try store.conversationInfo(id: conv)
        print("REALZIP dopo il primo: messaggi=\(info1.messageCount) allegati=\(info1.attachmentCount) file=\(store.media.allFiles().count)")

        // 2. Secondo file nella stessa chat, abbinando i nomi diversi.
        let second = try timed("apertura zip 2") { try ZipSource(url: URL(fileURLWithPath: paths[1])) }
        let sug2 = try importer.suggest(second)
        print("REALZIP proposta 2: chatRiconosciuta=\(sug2.matchedConversationID != nil) ioRiconosciuto=\(sug2.likelyMe != nil)")
        var map: [String: ParticipantChoice] = [:]
        for name in sug2.senders {
            let mine = name.lowercased().hasPrefix("dem")
            map[name] = .existing(info1.participants.first { $0.isMe == mine }!.id)
        }
        let plan2 = try timed("analisi 2") { try importer.analyze(second, target: .existing(conversationID: conv, senders: map)) }
        show("secondo", plan2.summary)
        try timed("scrittura 2") { _ = try importer.apply(plan2) }
        let info2 = try store.conversationInfo(id: conv)
        print("REALZIP dopo il secondo: messaggi=\(info2.messageCount) allegati=\(info2.attachmentCount) partecipanti=\(info2.participants.count) alias=\(info2.participants.map(\.aliases.count))")
        XCTAssertEqual(info2.messageCount, plan1.summary.newMessages + plan2.summary.newMessages)
        XCTAssertEqual(info2.participants.count, 2)

        // 3. Reimportare entrambi: nulla di nuovo.
        for (i, path) in paths.enumerated() {
            let again = try ZipSource(url: URL(fileURLWithPath: path))
            let plan = try timed("analisi ripetuta \(i + 1)") { try importer.analyze(again, target: .existing(conversationID: conv, senders: [:])) }
            show("ripetuto \(i + 1)", plan.summary)
            XCTAssertEqual(plan.summary.newMessages, 0)
            XCTAssertEqual(plan.summary.attachmentsToLink, 0)
        }

        // 4. Vocali riproducibili e file su disco.
        let audio = try store.db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment WHERE kind = 'audio'")!,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment WHERE kind = 'audio' AND playable_hash IS NOT NULL")!)
        }
        print("REALZIP vocali=\(audio.0) riproducibili=\(audio.1) spazio=\(store.diskUsage() / 1_000_000)MB integrità=\(try store.db.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") ?? "?" })")
        let missingOnDisk = try store.db.read { db -> Int in
            var n = 0
            for row in try Row.fetchAll(db, sql: "SELECT file_name, sha256 FROM attachment") {
                let name: String = row["file_name"]
                if !FileManager.default.fileExists(atPath: store.media.url(forHash: row["sha256"], ext: (name as NSString).pathExtension).path) { n += 1 }
            }
            return n
        }
        XCTAssertEqual(missingOnDisk, 0)

        // 5. Tempi delle letture usate dall'interfaccia, con circa 100.000 messaggi.
        _ = try timed("elenco chat") { try store.chatList() }
        let last = try timed("ultimi 150 messaggi") { try store.messages(conversationID: conv, around: nil, limit: 150) }
        _ = try timed("pagina precedente") { try store.messages(conversationID: conv, before: last[0], limit: 150) }
        let hits = try timed("ricerca parola") { try store.search(SearchFilter(text: "you"), limit: 300) }
        _ = try timed("ricerca frase") { try store.search(SearchFilter(text: "i love you", conversationID: conv), limit: 300) }
        _ = try timed("ricerca per giorno") { try store.search(SearchFilter(day: last[0].day, conversationID: conv), limit: 300) }
        if let hit = hits.last { _ = try timed("salto a un messaggio") { try store.messages(conversationID: conv, around: hit.message.id, limit: 300) } }
        _ = try timed("raccolta media") { try store.mediaItems(conversationID: conv, section: .media, limit: 240, offset: 0) }
        _ = try timed("raccolta sticker") { try store.mediaItems(conversationID: conv, section: .stickers, limit: 240, offset: 0) }
        _ = try timed("scheda chat") { try store.conversationInfo(id: conv) }
        print("REALZIP risultati ricerca=\(hits.count)")

        // 6. Annullare l'ultima importazione riporta ai numeri del primo file.
        try timed("annullamento") { try importer.undoLastImport(conversationID: conv) }
        let info3 = try store.conversationInfo(id: conv)
        print("REALZIP dopo l'annullamento: messaggi=\(info3.messageCount) allegati=\(info3.attachmentCount) file=\(store.media.allFiles().count)")
        XCTAssertEqual(info3.messageCount, info1.messageCount)
        XCTAssertEqual(info3.attachmentCount, info1.attachmentCount)
    }
}
