import XCTest
import GRDB
@testable import ArchivioCore

final class QueryTests: StoreTestCase {
    private let t = Fixtures.start

    func testChatList() throws {
        try importNew(Fixtures.makeChat(count: 5), title: "Ash")
        try importNew(Fixtures.line(t + 999_999, "Bea", "ultimo di Bea"), name: "b.txt", title: "Bea", me: nil)
        var list = try store.chatList()
        XCTAssertEqual(list.map(\.title), ["Bea", "Ash"])
        XCTAssertEqual(list[0].lastText, "ultimo di Bea")
        XCTAssertEqual(list[1].lastText, "messaggio numero 4")
        XCTAssertEqual(list[1].messageCount, 5)
        XCTAssertEqual(list[1].starredCount, 0)
        XCTAssertEqual(list[1].lastIsMe, true)

        let first = try store.messages(conversationID: list[1].id, around: nil, limit: 10)[0]
        try store.setStar(messageID: first.id, true)
        list = try store.chatList()
        XCTAssertEqual(list[1].starredCount, 1)
    }

    func testPagingHasNoGapsOrRepeats() throws {
        // 1.000 messaggi, quattro per secondo: l'ordine dentro il secondo deve reggere.
        var text = ""
        for i in 0..<1000 { text += Fixtures.line(t + Int64(i / 4), i % 2 == 0 ? "Io" : "Ash", "m\(i)") }
        try importNew(text)
        let conv = try conversationID()
        let expected = (0..<1000).map { "m\($0)" }

        var window = try store.messages(conversationID: conv, around: nil, limit: 70)
        XCTAssertEqual(window.map(\.text), Array(expected.suffix(70)))
        var all = window
        while true {
            let older = try store.messages(conversationID: conv, before: all.first!, limit: 70)
            if older.isEmpty { break }
            all.insert(contentsOf: older, at: 0)
        }
        XCTAssertEqual(all.map(\.text), expected)

        window = try store.messages(conversationID: conv, around: all[300].id, limit: 50)
        XCTAssertTrue(window.contains { $0.id == all[300].id })
        XCTAssertEqual(window.map(\.text), Array(expected[275..<325]))
        var forward = window
        while true {
            let newer = try store.messages(conversationID: conv, after: forward.last!, limit: 70)
            if newer.isEmpty { break }
            forward.append(contentsOf: newer)
        }
        XCTAssertEqual(forward.map(\.text), Array(expected[275...]))
        XCTAssertEqual(all[0].isMe, true)
        XCTAssertEqual(all[1].senderName, "Ash")
    }

    func testSearch() throws {
        let text = Fixtures.line(t, "Ash", "Domani andiamo al mare")
            + Fixtures.line(t + 60, "Io", "perché no, andiamo")
            + Fixtures.line(t + 86_400, "Ash", "il mare era bellissimo")
            + Fixtures.line(t + 86_460, "Io", "100% d'accordo \"davvero\" *")
            + Fixtures.line(t + 86_520, "Ash", "😂😂")
        try importNew(text)
        let conv = try conversationID()
        let ash = try store.db.read { try Int64.fetchOne($0, sql: "SELECT id FROM participant WHERE display_name = 'Ash'")! }

        func texts(_ f: SearchFilter) throws -> [String] { try store.search(f, limit: 50).map(\.message.text) }

        XCTAssertEqual(try texts(SearchFilter(text: "mare")), ["il mare era bellissimo", "Domani andiamo al mare"])
        XCTAssertEqual(try texts(SearchFilter(text: "MARE")).count, 2)
        XCTAssertEqual(try texts(SearchFilter(text: "andiamo al mare")), ["Domani andiamo al mare"])   // frase
        XCTAssertEqual(try texts(SearchFilter(text: "perche")), ["perché no, andiamo"])                // accento
        XCTAssertEqual(try texts(SearchFilter(text: "bell")), ["il mare era bellissimo"])              // inizio di parola
        XCTAssertEqual(try texts(SearchFilter(text: "mare domani")), ["Domani andiamo al mare"])       // parole non vicine
        XCTAssertEqual(try texts(SearchFilter(text: "andiamo", participantID: ash)), ["Domani andiamo al mare"])
        XCTAssertEqual(try texts(SearchFilter(day: t + 86_400 - (t + 86_400) % 86_400)).count, 3)
        XCTAssertEqual(try texts(SearchFilter(text: "mare", day: t - t % 86_400)), ["Domani andiamo al mare"])
        XCTAssertEqual(try texts(SearchFilter(text: "mare", conversationID: conv + 99)), [])
        XCTAssertEqual(try texts(SearchFilter(text: "😂")), ["😂😂"])

        // Caratteri speciali della ricerca non devono dare errori.
        for odd in ["\"", "*", "100%", "d'accordo", "(", "a AND", "NEAR(", "-", "  ", "\"davvero\" *"] {
            XCTAssertNoThrow(try texts(SearchFilter(text: odd)), odd)
        }
        XCTAssertEqual(try texts(SearchFilter(text: "100%")), ["100% d'accordo \"davvero\" *"])

        let hit = try store.search(SearchFilter(text: "bellissimo"), limit: 5)[0]
        try store.setStar(messageID: hit.message.id, true)
        XCTAssertEqual(try texts(SearchFilter(starredOnly: true)), ["il mare era bellissimo"])
        XCTAssertEqual(try texts(SearchFilter(text: "andiamo", starredOnly: true)), [])
        XCTAssertEqual(hit.conversationTitle, "Ash")
    }

    func testStars() throws {
        try importNew(Fixtures.makeChat(count: 3))
        let rows = try store.messages(conversationID: try conversationID(), around: nil, limit: 10)
        try store.setStar(messageID: rows[1].id, true)
        try store.setStar(messageID: rows[1].id, true)      // due volte: nessun errore
        XCTAssertEqual(try store.starred().map(\.message.id), [rows[1].id])
        XCTAssertTrue(try store.message(id: rows[1].id)!.starred)
        // La stella non tocca il messaggio.
        XCTAssertEqual(try store.message(id: rows[1].id)!.text, rows[1].text)
        try store.setStar(messageID: rows[1].id, false)
        XCTAssertEqual(try store.starred().count, 0)
    }

    func testMediaSectionsAndInfo() throws {
        let url = dir.appendingPathComponent("m.zip")
        var chat = Fixtures.line(t, "Io", "guarda https://esempio.it/pagina")
        chat += Fixtures.attach(t + 1, "Ash", "1-PHOTO-a.jpg")
        chat += Fixtures.attach(t + 2, "Ash", "2-VIDEO-a.mp4")
        chat += Fixtures.attach(t + 3, "Ash", "3-STICKER-a.webp")
        chat += Fixtures.attach(t + 4, "Ash", "4-AUDIO-a.m4a")
        chat += Fixtures.attach(t + 5, "Ash", "relazione.pdf")
        chat += Fixtures.line(t + 6, "Ash", "\u{200E}immagine omessa")
        try Fixtures.makeZip(at: url, chat: chat, files: [
            ("1-PHOTO-a.jpg", Fixtures.image(seed: 1)), ("2-VIDEO-a.mp4", Fixtures.bytes(2)),
            ("3-STICKER-a.webp", Fixtures.bytes(3)), ("4-AUDIO-a.m4a", Fixtures.bytes(4)), ("relazione.pdf", Fixtures.bytes(5)),
        ])
        let plan = try importer.analyze(try ZipSource(url: url), target: .newConversation(title: "Ash", me: "Io"))
        try importer.apply(plan)
        let conv = try conversationID()

        XCTAssertEqual(try store.mediaItems(conversationID: conv, section: .media, limit: 50, offset: 0).map(\.kind), [.video, .photo])
        XCTAssertEqual(try store.mediaItems(conversationID: conv, section: .stickers, limit: 50, offset: 0).count, 1)
        XCTAssertEqual(try store.mediaItems(conversationID: conv, section: .audio, limit: 50, offset: 0).count, 1)
        XCTAssertEqual(try store.mediaItems(conversationID: conv, section: .documents, limit: 50, offset: 0).first?.attachment?.fileName, "relazione.pdf")
        XCTAssertEqual(try store.mediaItems(conversationID: conv, section: .links, limit: 50, offset: 0).count, 1)

        let rows = try store.messages(conversationID: conv, around: nil, limit: 50)
        XCTAssertTrue(rows.last!.mediaMissing)
        XCTAssertFalse(rows[1].mediaMissing)
        XCTAssertEqual(rows[1].attachment?.ext, "jpg")

        let info = try store.conversationInfo(id: conv)
        XCTAssertEqual(info.title, "Ash")
        XCTAssertEqual(info.messageCount, 7)
        XCTAssertEqual(info.firstTS, t)
        XCTAssertEqual(info.lastTS, t + 6)
        XCTAssertEqual(info.attachmentCount, 5)
        XCTAssertEqual(info.participants.map(\.displayName).sorted(), ["Ash", "Io"])
        XCTAssertEqual(info.participants.first { $0.isMe }?.aliases, ["Io"])
        XCTAssertEqual(info.imports.count, 1)
        XCTAssertEqual(info.imports[0].summary?.newMessages, 7)

        try store.rename(conversationID: conv, to: "Nuovo nome")
        let ash = info.participants.first { !$0.isMe }!
        try store.setMe(conversationID: conv, participantID: ash.id)
        let after = try store.conversationInfo(id: conv)
        XCTAssertEqual(after.title, "Nuovo nome")
        XCTAssertEqual(after.participants.filter(\.isMe).map(\.displayName), ["Ash"])

        try store.deleteConversation(id: conv)
        XCTAssertEqual(try count("message"), 0)
        XCTAssertEqual(store.media.allFiles().count, 0)
    }
}
