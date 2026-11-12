import XCTest
import GRDB
@testable import ArchivioCore

class StoreTestCase: TempDirTestCase {
    var store: ArchiveStore!
    var importer: Importer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ArchiveStore(directory: dir.appendingPathComponent("archivio"))
        importer = Importer(store: store)
    }

    override func tearDownWithError() throws {
        importer = nil
        store = nil
        try super.tearDownWithError()
    }

    @discardableResult
    func importNew(_ text: String, name: String = "chat.txt", title: String = "Ash", me: String? = "Io") throws -> ImportSummary {
        let src = TextFileSource(url: try write(text, name: name))
        let plan = try importer.analyze(src, target: .newConversation(title: title, me: me))
        try importer.apply(plan)
        return plan.summary
    }

    @discardableResult
    func importInto(_ conv: Int64, _ text: String, name: String = "chat2.txt",
                    senders: [String: ParticipantChoice] = [:]) throws -> ImportSummary {
        let src = TextFileSource(url: try write(text, name: name))
        let plan = try importer.analyze(src, target: .existing(conversationID: conv, senders: senders))
        try importer.apply(plan)
        return plan.summary
    }

    func conversationID() throws -> Int64 {
        try store.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM conversation ORDER BY id LIMIT 1")! }
    }

    func count(_ table: String) throws -> Int {
        try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)")! }
    }

    /// Contenuto completo delle tabelle, per confronti "identico a prima".
    func dump(includeUndoneBatches: Bool = true) throws -> [String] {
        try store.db.read { db in
            var out: [String] = []
            for table in ["conversation", "participant", "participant_alias", "message", "attachment", "star"] {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1") {
                    out.append("\(table): \(row.description)")
                }
            }
            let batchSQL = includeUndoneBatches ? "SELECT * FROM import_batch ORDER BY id"
                : "SELECT * FROM import_batch WHERE status = 'applied' ORDER BY id"
            for row in try Row.fetchAll(db, sql: batchSQL) { out.append("import_batch: \(row.description)") }
            return out
        }
    }
}

final class ImportScenarioTests: StoreTestCase {

    func testStoreOpensAndMigrates() throws {
        let tables = try store.db.read {
            try String.fetchAll($0, sql: "SELECT name FROM sqlite_master WHERE type IN ('table') ORDER BY name")
        }
        for t in ["conversation", "participant", "participant_alias", "import_batch", "message", "attachment", "star", "message_fts"] {
            XCTAssertTrue(tables.contains(t), "manca \(t)")
        }
        XCTAssertEqual(try store.db.read { try Int.fetchOne($0, sql: "PRAGMA foreign_keys") }, 1)
        store = nil; importer = nil
        XCTAssertNoThrow(try ArchiveStore(directory: dir.appendingPathComponent("archivio")))
    }

    // Test 1 della specifica
    func test1_thousand() throws {
        let s = try importNew(Fixtures.makeChat(count: 1000))
        XCTAssertEqual(s.newMessages, 1000)
        XCTAssertEqual(s.alreadyPresent, 0)
        XCTAssertEqual(try count("message"), 1000)
        XCTAssertEqual(try count("conversation"), 1)
        XCTAssertEqual(try count("participant"), 2)
        let me = try store.db.read { try String.fetchOne($0, sql: "SELECT display_name FROM participant WHERE is_me = 1") }
        XCTAssertEqual(me, "Io")
    }

    // Test 2 della specifica
    func test2_overlap() throws {
        try importNew(Fixtures.makeChat(count: 1000))
        let before = try store.db.read { try Row.fetchAll($0, sql: "SELECT id, ts, text, participant_id FROM message ORDER BY id") }
        let s = try importInto(try conversationID(), Fixtures.makeChat(from: 500, count: 800))
        XCTAssertEqual(s.alreadyPresent, 500)
        XCTAssertEqual(s.newMessages, 300)
        XCTAssertEqual(s.possibleDuplicates, 0)
        XCTAssertTrue(s.overlaps)
        XCTAssertEqual(try count("message"), 1300)
        let after = try store.db.read { try Row.fetchAll($0, sql: "SELECT id, ts, text, participant_id FROM message WHERE id <= ? ORDER BY id", arguments: [before.last!["id"] as Int64]) }
        XCTAssertEqual(before, after)
        XCTAssertEqual(try count("participant"), 2)
        let distinct = try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT text) FROM message")! }
        XCTAssertEqual(distinct, 1300)
    }

    // Test 3 della specifica
    func test3_sameFileTwice() throws {
        let text = Fixtures.makeChat(count: 400)
        try importNew(text)
        let s = try importInto(try conversationID(), text)
        XCTAssertEqual(s.newMessages, 0)
        XCTAssertEqual(s.alreadyPresent, 400)
        XCTAssertEqual(try count("message"), 400)
    }

    // Test 6 della specifica
    func test6_sameTextDifferentTime() throws {
        try importNew(Fixtures.line(Fixtures.start, "Ash", "buonanotte"))
        let s = try importInto(try conversationID(), Fixtures.line(Fixtures.start + 86_400, "Ash", "buonanotte"))
        XCTAssertEqual(s.newMessages, 1)
        XCTAssertEqual(try count("message"), 2)
    }

    // Test 7 della specifica
    func test7_interrupted() throws {
        try importNew(Fixtures.makeChat(count: 1000))
        let before = try dump()
        let src = TextFileSource(url: try write(Fixtures.makeChat(from: 500, count: 800), name: "b.txt"))
        let plan = try importer.analyze(src, target: .existing(conversationID: try conversationID(), senders: [:]))
        struct Boom: Error {}
        var steps = 0
        importer.failureInjection = { step in steps = step; if step == 3 { throw Boom() } }
        XCTAssertThrowsError(try importer.apply(plan)) { XCTAssertTrue($0 is Boom) }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(try store.db.read { try String.fetchOne($0, sql: "PRAGMA integrity_check") }, "ok")
        XCTAssertEqual(try count("message"), 1000)
        // L'archivio resta utilizzabile: la stessa importazione, senza guasto, va a buon fine.
        importer.failureInjection = nil
        try importer.apply(plan)
        XCTAssertEqual(try count("message"), 1300)
    }

    // Ripetizioni vere nello stesso secondo
    func test8_realRepeats() throws {
        let t = Fixtures.start
        let text = Fixtures.line(t, "Ash", "ahah") + Fixtures.line(t, "Ash", "ahah") + Fixtures.line(t, "Ash", "ahah")
            + Fixtures.line(t, "Io", "ahah")
        try importNew(text)
        XCTAssertEqual(try count("message"), 4)
        let s = try importInto(try conversationID(), text)
        XCTAssertEqual(s.newMessages, 0)
        XCTAssertEqual(try count("message"), 4)
    }

    // Stessa persona con nomi diversi
    func test9_aliases() throws {
        try importNew(Fixtures.makeChat(count: 300, senders: ["demox18", "Hamburger"]), me: "demox18")
        let conv = try conversationID()
        let ids = try store.db.read { db in
            (me: try Int64.fetchOne(db, sql: "SELECT id FROM participant WHERE is_me = 1")!,
             other: try Int64.fetchOne(db, sql: "SELECT id FROM participant WHERE is_me = 0")!)
        }
        let s = try importInto(conv, Fixtures.makeChat(from: 100, count: 400, senders: ["demy", "sorrysora"]),
                               senders: ["demy": .existing(ids.me), "sorrysora": .existing(ids.other)])
        XCTAssertEqual(s.alreadyPresent, 200)
        XCTAssertEqual(s.newMessages, 200)
        XCTAssertEqual(try count("message"), 500)
        XCTAssertEqual(try count("participant"), 2)
        XCTAssertEqual(try count("participant_alias"), 4)
        // Alla terza importazione gli alias sono già noti: nessuna mappa necessaria.
        let s3 = try importInto(conv, Fixtures.makeChat(from: 100, count: 400, senders: ["demy", "sorrysora"]), name: "c.txt")
        XCTAssertEqual(s3.newMessages, 0)
        XCTAssertEqual(try count("participant"), 2)
    }

    func testUnknownSenderBecomesNewParticipant() throws {
        try importNew(Fixtures.makeChat(count: 10))
        let s = try importInto(try conversationID(), Fixtures.line(Fixtures.start, "Sconosciuto", "ciao"))
        XCTAssertEqual(s.newMessages, 1)
        XCTAssertEqual(try count("participant"), 3)
    }

    // Annullamento
    func test10_undo() throws {
        try importNew(Fixtures.makeChat(count: 200))
        let conv = try conversationID()
        let before = try dump(includeUndoneBatches: false)

        try importInto(conv, Fixtures.makeChat(from: 100, count: 300) + Fixtures.line(Fixtures.start + 5, "Nuovo", "eccomi"))
        XCTAssertEqual(try count("message"), 401)
        XCTAssertEqual(try count("participant"), 3)
        let newest = try store.db.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM message")! }
        try store.db.write { try $0.execute(sql: "INSERT INTO star(message_id, created_at) VALUES (?, 0)", arguments: [newest]) }

        let info = try XCTUnwrap(try importer.canUndo(conversationID: conv))
        XCTAssertEqual(info.starsLost, 1)
        try importer.undoLastImport(conversationID: conv)
        XCTAssertEqual(try dump(includeUndoneBatches: false), before)

        // Il secondo annullamento agisce sulla prima importazione e toglie la conversazione.
        XCTAssertNotNil(try importer.canUndo(conversationID: conv))
        try importer.undoLastImport(conversationID: conv)
        XCTAssertEqual(try count("conversation"), 0)
        XCTAssertEqual(try count("message"), 0)
        XCTAssertNil(try importer.canUndo(conversationID: conv))
    }

    // Regola delle date: senza sovrapposizione il file si aggiunge e basta
    func test11_noOverlap() throws {
        try importNew(Fixtures.makeChat(count: 100))
        let later = Fixtures.start + 365 * 86_400
        let s = try importInto(try conversationID(), Fixtures.makeChat(count: 100, start: later))
        XCTAssertFalse(s.overlaps)
        XCTAssertEqual(s.newMessages, 100)
        XCTAssertEqual(s.alreadyPresent, 0)
        let ts = try store.db.read { try Int64.fetchAll($0, sql: "SELECT ts FROM message ORDER BY ts, batch_id, seq") }
        XCTAssertEqual(ts.count, 200)
        XCTAssertEqual(ts, ts.sorted())
        XCTAssertEqual(ts[100], later)
    }

    func testOlderExportImportedLaterIsInterleaved() throws {
        try importNew(Fixtures.makeChat(count: 100, start: Fixtures.start + 365 * 86_400))
        try importInto(try conversationID(), Fixtures.makeChat(count: 100))
        let first = try store.db.read { try Int64.fetchOne($0, sql: "SELECT ts FROM message ORDER BY ts, batch_id, seq LIMIT 1") }
        XCTAssertEqual(first, Fixtures.start)
    }

    func testSameSecondKeepsFileOrder() throws {
        let t = Fixtures.start
        try importNew(Fixtures.line(t, "Ash", "primo") + Fixtures.line(t, "Io", "secondo") + Fixtures.line(t, "Ash", "terzo"))
        let texts = try store.db.read { try String.fetchAll($0, sql: "SELECT text FROM message ORDER BY ts, batch_id, seq") }
        XCTAssertEqual(texts, ["primo", "secondo", "terzo"])
    }

    func testSuggestMatchesByAlias() throws {
        try importNew(Fixtures.makeChat(count: 10, senders: ["Io", "Ash"]))
        let src = TextFileSource(url: try write(Fixtures.makeChat(count: 5, senders: ["Ash", "Altro"]), name: "WhatsApp Chat - Ash 2026.txt"))
        let sug = try importer.suggest(src)
        XCTAssertEqual(sug.matchedConversationID, try conversationID())
        XCTAssertEqual(sug.senders, ["Ash", "Altro"])
        XCTAssertEqual(sug.suggestedTitle, "Ash 2026")

        let other = TextFileSource(url: try write(Fixtures.makeChat(count: 5, senders: ["X", "Y"]), name: "_chat.txt"))
        XCTAssertNil(try importer.suggest(other).matchedConversationID)
    }

    func testArchiveChangedBetweenAnalyzeAndApply() throws {
        try importNew(Fixtures.makeChat(count: 10))
        let conv = try conversationID()
        let src = TextFileSource(url: try write(Fixtures.makeChat(from: 5, count: 10), name: "b.txt"))
        let stale = try importer.analyze(src, target: .existing(conversationID: conv, senders: [:]))
        try importInto(conv, Fixtures.makeChat(from: 5, count: 10), name: "c.txt")
        XCTAssertThrowsError(try importer.apply(stale)) { XCTAssertEqual($0 as? ImportError, .archiveChanged) }
        XCTAssertEqual(try count("message"), 15)
    }

    func testEmptyFileIsRejected() throws {
        let src = TextFileSource(url: try write("", name: "vuoto.txt"))
        XCTAssertThrowsError(try importer.analyze(src, target: .newConversation(title: "x", me: nil))) {
            XCTAssertEqual($0 as? ImportError, .noMessages)
        }
        XCTAssertEqual(try count("conversation"), 0)
    }

    func testSearchIndexFollowsImportAndUndo() throws {
        try importNew(Fixtures.line(Fixtures.start, "Ash", "parola rarissima"))
        let hits = { try self.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM message_fts WHERE message_fts MATCH 'rarissima'")! } }
        XCTAssertEqual(try hits(), 1)
        try importer.undoLastImport(conversationID: try conversationID())
        XCTAssertEqual(try hits(), 0)
    }
}
