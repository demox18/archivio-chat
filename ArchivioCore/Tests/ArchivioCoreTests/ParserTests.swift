import XCTest
@testable import ArchivioCore

final class ParserTests: XCTestCase {
    private func parse(_ s: String) -> ParseResult { ChatParser.parse(Data(s.utf8)) }

    func testBasicLine() {
        let r = parse("[05/08/24, 01:48:41] Ash: ciao\r\n")
        XCTAssertEqual(r.messages.count, 1)
        let m = r.messages[0]
        XCTAssertEqual(m.ts, 1_722_822_521)
        XCTAssertEqual(m.sender, "Ash")
        XCTAssertEqual(m.kind, .text)
        XCTAssertEqual(m.text, "ciao")
        XCTAssertEqual(m.line, 1)
        XCTAssertFalse(m.edited)
        XCTAssertEqual(r.senders, ["Ash"])
        XCTAssertEqual(r.unrecognizedLines, 0)
    }

    func testContinuation() {
        let r = parse("[05/08/24, 01:48:41] Ash: a\r\nb\r\nc\r\n[05/08/24, 01:48:42] Io: d\r\n")
        XCTAssertEqual(r.messages.count, 2)
        XCTAssertEqual(r.messages[0].text, "a\nb\nc")
        XCTAssertEqual(r.messages[1].line, 4)
    }

    func testEmptyBody() {
        let r = parse("[05/08/24, 01:48:41] Ash:\r\nseconda riga\r\n[05/08/24, 01:48:42] Ash: \r\n")
        XCTAssertEqual(r.messages.count, 2)
        XCTAssertEqual(r.messages[0].sender, "Ash")
        XCTAssertEqual(r.messages[0].kind, .text)
        XCTAssertEqual(r.messages[0].text, "\nseconda riga")
        XCTAssertEqual(r.messages[1].text, "")
    }

    func testAttachmentKinds() {
        let names: [(String, MessageKind)] = [
            ("00000012-PHOTO-2025-08-22-13-44-43.jpg", .photo),
            ("00000013-VIDEO-2025-08-22-13-44-43.mp4", .video),
            ("00000014-GIF-2025-08-22-13-44-43.mp4", .gif),
            ("00000015-STICKER-2025-08-22-13-44-43.webp", .sticker),
            ("00000016-AUDIO-2025-08-22-13-44-43.opus", .audio),
            ("relazione finale.pdf", .document),
        ]
        var text = ""
        for (n, _) in names { text += "[22/08/25, 13:44:43] Ash: \u{200E}<allegato: \(n)>\r\n" }
        let r = parse(text)
        XCTAssertEqual(r.messages.count, names.count)
        for (m, (n, k)) in zip(r.messages, names) {
            XCTAssertEqual(m.kind, k, n)
            XCTAssertEqual(m.attachmentName, n)
            XCTAssertEqual(m.text, "")
        }
    }

    func testAttachmentWithCaption() {
        let r = parse("[22/08/25, 13:44:43] Ash: guarda \u{200E}<allegato: 00000012-PHOTO-2025-08-22-13-44-43.jpg>\r\n")
        XCTAssertEqual(r.messages[0].kind, .photo)
        XCTAssertEqual(r.messages[0].text, "guarda")
    }

    func testOmitted() {
        let markers: [(String, MessageKind)] = [
            ("immagine omessa", .photo), ("video omesso", .video), ("audio omesso", .audio),
            ("sticker non incluso", .sticker), ("GIF esclusa", .gif), ("documento omesso", .document),
            ("image omitted", .photo), ("sticker omitted", .sticker),
        ]
        var text = ""
        for (m, _) in markers { text += "[22/08/25, 13:44:43] Ash: \u{200E}\(m)\r\n" }
        let r = parse(text)
        for (m, (name, k)) in zip(r.messages, markers) {
            XCTAssertEqual(m.kind, k, name)
            XCTAssertNil(m.attachmentName)
            XCTAssertEqual(m.text, "")
        }
    }

    func testServiceLines() {
        let r = parse("""
        [22/08/25, 13:44:43] Ash: \u{200E}Chiamata vocale. \u{200E}12 minuti\r
        [22/08/25, 13:44:44] Io: \u{200E}Hai eliminato questo messaggio.\r
        [22/08/25, 13:44:45] Ash: \u{200E}Questo messaggio è stato eliminato.\r
        [22/08/25, 13:44:46] Ash: \u{200E}Hai bloccato questa persona\r
        [22/08/25, 13:44:47] Ash: \u{200E}Videochiamata. \u{200E}2 ore\r
        [22/08/25, 13:44:48] Ash: Chiamata dopo?\r

        """)
        XCTAssertEqual(r.messages.map(\.kind), [.call, .deleted, .deleted, .system, .call, .text])
        XCTAssertEqual(r.messages[0].text, "Chiamata vocale. 12 minuti")
        XCTAssertEqual(r.messages[3].text, "Hai bloccato questa persona")
    }

    func testEdited() {
        let r = parse("[22/08/25, 13:44:43] Ash: va bene \u{200E}<Questo messaggio è stato modificato>\r\n")
        XCTAssertEqual(r.messages[0].text, "va bene")
        XCTAssertTrue(r.messages[0].edited)
        XCTAssertEqual(r.messages[0].kind, .text)
    }

    func testEnglishMonthFirst() {
        let r = parse("[8/22/25, 1:44:05 PM] Ash: hi\n[8/3/25, 12:00:00 AM] Ash: midnight\n")
        // 22 agosto 2025 13:44:05
        XCTAssertEqual(r.messages[0].ts, 1_755_870_245)
        // 3 agosto 2025 00:00:00
        XCTAssertEqual(r.messages[1].ts, 1_754_179_200)
    }

    func testLeadingMarkBeforeBracket() {
        let r = parse("\u{200E}[22/08/25, 13:44:43] Ash: \u{200E}<allegato: 00000012-PHOTO-2025-08-22-13-44-43.jpg>\r\n")
        XCTAssertEqual(r.messages.count, 1)
        XCTAssertEqual(r.messages[0].kind, .photo)
    }

    /// Review Focus 3: nessuna riga deve andare persa, qualunque cosa contenga il file.
    func testRobustness() {
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("riga iniziale senza intestazione\n".utf8))
        bytes.append(Data("[05/08/24, 01:48:41] Dr: Rossi: buongiorno\n".utf8))
        bytes.append(Data("[non una data] x\n".utf8))
        bytes.append(Data("[99/99/99, 99:99:99] finta: intestazione\n".utf8))
        bytes.append(Data("byte strano ".utf8)); bytes.append(0xFF); bytes.append(Data("\n".utf8))
        bytes.append(Data("[05/08/24, 01:48:50] Ash: fine".utf8))   // senza a capo finale

        let r = ChatParser.parse(bytes)
        XCTAssertEqual(r.unrecognizedLines, 1)
        XCTAssertEqual(r.messages.count, 3)
        XCTAssertEqual(r.messages[0].kind, .system)
        XCTAssertEqual(r.messages[0].text, "riga iniziale senza intestazione")
        XCTAssertEqual(r.messages[1].sender, "Dr")
        XCTAssertTrue(r.messages[1].text.hasPrefix("Rossi: buongiorno\n[non una data] x\n[99/99/99, 99:99:99] finta: intestazione\nbyte strano "))
        XCTAssertEqual(r.messages[2].text, "fine")
        // 6 righe in ingresso = somma delle righe ricostruite
        let lines = r.messages.reduce(0) { $0 + $1.text.components(separatedBy: "\n").count }
        XCTAssertEqual(lines, 6)
    }

    func testNoSenderLineIsSystem() {
        let r = parse("[05/08/24, 01:48:41] Hai creato il gruppo\r\n")
        XCTAssertEqual(r.messages[0].kind, .system)
        XCTAssertNil(r.messages[0].sender)
        XCTAssertEqual(r.messages[0].text, "Hai creato il gruppo")
    }

    func testEmptyInput() {
        XCTAssertEqual(parse("").messages.count, 0)
    }
}
