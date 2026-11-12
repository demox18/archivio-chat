import XCTest
import GRDB
import ZIPFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import ArchivioCore

extension Fixtures {
    /// Una piccola immagine vera; `seed` cambia il colore, quindi il contenuto.
    static func image(seed: Int, type: UTType = .jpeg, size: Int = 8) -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: CGFloat(seed % 7) / 7, green: CGFloat(seed % 13) / 13, blue: CGFloat(seed % 5) / 5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func bytes(_ seed: Int, count: Int = 64) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ seed &* 17) & 0xFF) })
    }

    static func makeZip(at url: URL, chat: String?, files: [(path: String, data: Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        func add(_ path: String, _ data: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        }
        if let chat { try add("_chat.txt", Data(chat.utf8)) }
        for f in files { try add(f.path, f.data) }
    }

    static func attach(_ ts: Int64, _ sender: String, _ name: String) -> String {
        line(ts, sender, "\u{200E}<allegato: \(name)>")
    }
}

final class MediaImportTests: StoreTestCase {
    private let t = Fixtures.start

    private func zipSource(_ name: String, chat: String?, files: [(path: String, data: Data)]) throws -> ZipSource {
        let url = dir.appendingPathComponent(name)
        try Fixtures.makeZip(at: url, chat: chat, files: files)
        return try ZipSource(url: url)
    }

    private func mediaFileCount() -> Int { store.media.allFiles().count }

    // Test 4 della specifica
    func test4_mediaImport() throws {
        var chat = "", files: [(path: String, data: Data)] = []
        func add(_ name: String, _ data: Data) {
            chat += Fixtures.attach(t + Int64(files.count), "Ash", name)
            files.append((name, data))
        }
        for i in 0..<3 { add("0000000\(i)-PHOTO-2024-01-01-10-00-0\(i).jpg", Fixtures.image(seed: i + 1)) }
        for i in 0..<2 { add("0000001\(i)-VIDEO-2024-01-01-10-00-1\(i).mp4", Fixtures.bytes(100 + i)) }
        for i in 0..<4 { add("0000002\(i)-STICKER-2024-01-01-10-00-2\(i).webp", Fixtures.bytes(200 + i)) }
        chat += Fixtures.line(t + 100, "Io", "belle")

        let src = try zipSource("chat.zip", chat: chat, files: files)
        let plan = try importer.analyze(src, target: .newConversation(title: "Ash", me: "Io"))
        XCTAssertEqual(plan.summary.photos, 3)
        XCTAssertEqual(plan.summary.videos, 2)
        XCTAssertEqual(plan.summary.stickers, 4)
        XCTAssertEqual(plan.summary.missingAttachments, 0)
        XCTAssertEqual(plan.summary.newMessages, 10)
        XCTAssertEqual(mediaFileCount(), 0, "l'analisi non deve scrivere nulla")
        try importer.apply(plan)

        XCTAssertEqual(try count("attachment"), 9)
        XCTAssertEqual(mediaFileCount(), 9)
        let rows = try store.db.read { try Row.fetchAll($0, sql: "SELECT file_name, sha256, byte_size, kind FROM attachment") }
        for row in rows {
            let name: String = row["file_name"]
            let url = store.media.url(forHash: row["sha256"], ext: (name as NSString).pathExtension)
            let original = files.first { $0.path == name }!.data
            XCTAssertEqual(try Data(contentsOf: url), original, name)
            XCTAssertEqual(row["byte_size"] as Int, original.count)
            XCTAssertEqual(try MediaStore.sha256(of: url).hash, row["sha256"] as String)
        }
        XCTAssertEqual(Set(rows.map { $0["kind"] as String }), ["photo", "video", "sticker"])
        // Il file ZIP originale non viene toccato.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.url.path))
    }

    // Test 5 della specifica: prima senza allegati (media omessi), poi con
    func test5_textThenMedia_omitted() throws {
        var plain = Fixtures.line(t, "Io", "guarda")
        for i in 1...3 { plain += Fixtures.line(t + Int64(i), "Ash", "\u{200E}immagine omessa") }
        plain += Fixtures.line(t + 10, "Io", "bella")
        try importNew(plain)
        let originalIDs = try store.db.read { try Int64.fetchAll($0, sql: "SELECT id FROM message WHERE kind = 'photo' ORDER BY id") }
        XCTAssertEqual(originalIDs.count, 3)

        var rich = Fixtures.line(t, "Io", "guarda"), files: [(path: String, data: Data)] = []
        for i in 1...3 {
            let name = "0000000\(i)-PHOTO-2024-01-01-10-00-0\(i).jpg"
            rich += Fixtures.attach(t + Int64(i), "Ash", name)
            files.append((name, Fixtures.image(seed: i)))
        }
        rich += Fixtures.line(t + 10, "Io", "bella")
        let plan = try importer.analyze(try zipSource("con-media.zip", chat: rich, files: files),
                                        target: .existing(conversationID: try conversationID(), senders: [:]))
        XCTAssertEqual(plan.summary.attachmentsToLink, 3)
        XCTAssertEqual(plan.summary.newMessages, 0)
        XCTAssertEqual(plan.summary.alreadyPresent, 5)
        try importer.apply(plan)

        XCTAssertEqual(try count("message"), 5)
        let linked = try store.db.read { try Int64.fetchAll($0, sql: "SELECT message_id FROM attachment ORDER BY message_id") }
        XCTAssertEqual(linked, originalIDs)
        XCTAssertEqual(mediaFileCount(), 3)

        // Reimportare lo ZIP non cambia più nulla.
        let again = try importer.analyze(try zipSource("con-media-2.zip", chat: rich, files: files),
                                         target: .existing(conversationID: try conversationID(), senders: [:]))
        XCTAssertEqual(again.summary.newMessages, 0)
        XCTAssertEqual(again.summary.attachmentsToLink, 0)
        try importer.apply(again)
        XCTAssertEqual(try count("attachment"), 3)
    }

    // Test 5, variante: il testo cita il nome del file, ma il file arriva dopo
    func test5b_namedButMissingThenZip() throws {
        let name = "00000001-PHOTO-2024-01-01-10-00-01.jpg"
        let chat = Fixtures.attach(t, "Ash", name) + Fixtures.line(t + 1, "Io", "ok")
        let first = try importNew(chat)
        XCTAssertEqual(first.missingAttachments, 1)
        XCTAssertEqual(try count("attachment"), 0)

        let plan = try importer.analyze(try zipSource("z.zip", chat: chat, files: [(name, Fixtures.image(seed: 3))]),
                                        target: .existing(conversationID: try conversationID(), senders: [:]))
        XCTAssertEqual(plan.summary.attachmentsToLink, 1)
        XCTAssertEqual(plan.summary.newMessages, 0)
        XCTAssertEqual(plan.summary.missingAttachments, 0)
        try importer.apply(plan)
        XCTAssertEqual(try count("message"), 2)
        XCTAssertEqual(try count("attachment"), 1)
    }

    func testSameFileDeduplicatedOnDisk() throws {
        let data = Fixtures.image(seed: 5)
        let chat = Fixtures.attach(t, "Ash", "a-PHOTO-1.jpg") + Fixtures.attach(t + 1, "Ash", "b-PHOTO-2.jpg")
        let plan = try importer.analyze(try zipSource("z.zip", chat: chat, files: [("a-PHOTO-1.jpg", data), ("b-PHOTO-2.jpg", data)]),
                                        target: .newConversation(title: "Ash", me: nil))
        try importer.apply(plan)
        XCTAssertEqual(try count("attachment"), 2)
        XCTAssertEqual(mediaFileCount(), 1)
    }

    /// Review Focus 2: i nomi dentro lo ZIP non devono poter scrivere fuori da `media/`.
    func testZipEntryNames() throws {
        let chat = Fixtures.attach(t, "Ash", "foto.jpg") + Fixtures.attach(t + 1, "Ash", "evil.jpg")
        let src = try zipSource("z.zip", chat: chat, files: [
            ("cartella/sotto/foto.jpg", Fixtures.image(seed: 1)),
            ("../../evil.jpg", Fixtures.image(seed: 2)),
            ("altra/foto.jpg", Fixtures.image(seed: 3)),
            ("__MACOSX/._foto.jpg", Fixtures.bytes(1)),
        ])
        XCTAssertEqual(src.attachmentNames, ["foto.jpg"])
        let plan = try importer.analyze(src, target: .newConversation(title: "Ash", me: nil))
        XCTAssertEqual(plan.summary.photos, 1)
        XCTAssertEqual(plan.summary.missingAttachments, 1)
        try importer.apply(plan)
        XCTAssertEqual(try count("attachment"), 1)
        let stored = store.media.allFiles()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(try Data(contentsOf: stored[0]), Fixtures.image(seed: 1), "a nomi ripetuti vince la prima voce")
        XCTAssertTrue(stored[0].standardizedFileURL.path.hasPrefix(store.media.root.standardizedFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("evil.jpg").path))
    }

    /// Review Focus 4: un guasto a metà copia non lascia tracce.
    func testFailureDuringCopyLeavesNothing() throws {
        try importNew(Fixtures.makeChat(count: 20))
        let before = try dump()
        var chat = "", files: [(path: String, data: Data)] = []
        for i in 0..<6 {
            let name = "f\(i)-PHOTO-x.jpg"
            chat += Fixtures.attach(t + 5000 + Int64(i), "Ash", name)
            files.append((name, Fixtures.image(seed: i + 1)))
        }
        let plan = try importer.analyze(try zipSource("z.zip", chat: chat, files: files),
                                        target: .existing(conversationID: try conversationID(), senders: [:]))
        struct Boom: Error {}
        importer.extractionInjection = { if $0 == 3 { throw Boom() } }
        XCTAssertThrowsError(try importer.apply(plan))
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(mediaFileCount(), 0)
        XCTAssertEqual(store.media.stagingFiles().count, 0)

        // Guasto nel database dopo che tutti i file sono stati copiati.
        importer.extractionInjection = nil
        importer.failureInjection = { _ in throw Boom() }
        var big = chat
        big += Fixtures.makeChat(count: 150, start: t + 9000)
        let plan2 = try importer.analyze(try zipSource("z2.zip", chat: big, files: files),
                                         target: .existing(conversationID: try conversationID(), senders: [:]))
        XCTAssertThrowsError(try importer.apply(plan2))
        XCTAssertEqual(try dump(), before)
        XCTAssertEqual(mediaFileCount(), 0)
    }

    /// Un guasto non deve cancellare file che c'erano già.
    func testFailureKeepsPreexistingFiles() throws {
        let data = Fixtures.image(seed: 9)
        let plan = try importer.analyze(try zipSource("a.zip", chat: Fixtures.attach(t, "Ash", "a-PHOTO-1.jpg"), files: [("a-PHOTO-1.jpg", data)]),
                                        target: .newConversation(title: "Ash", me: nil))
        try importer.apply(plan)
        XCTAssertEqual(mediaFileCount(), 1)

        let chat2 = Fixtures.attach(t + 50, "Ash", "stessa-PHOTO-2.jpg") + Fixtures.attach(t + 51, "Ash", "nuova-PHOTO-3.jpg")
        let plan2 = try importer.analyze(try zipSource("b.zip", chat: chat2, files: [("stessa-PHOTO-2.jpg", data), ("nuova-PHOTO-3.jpg", Fixtures.image(seed: 10))]),
                                         target: .existing(conversationID: try conversationID(), senders: [:]))
        struct Boom: Error {}
        importer.extractionInjection = { if $0 == 2 { throw Boom() } }   // dopo entrambe le copie non scatta
        importer.failureInjection = nil
        try importer.apply(plan2)
        XCTAssertEqual(mediaFileCount(), 2)

        // Ora un'importazione che fallisce e che riusa il file già presente.
        let chat3 = Fixtures.attach(t + 60, "Ash", "ancora-PHOTO-4.jpg") + Fixtures.attach(t + 61, "Ash", "altra-PHOTO-5.jpg")
        let plan3 = try importer.analyze(try zipSource("c.zip", chat: chat3, files: [("ancora-PHOTO-4.jpg", data), ("altra-PHOTO-5.jpg", Fixtures.image(seed: 11))]),
                                         target: .existing(conversationID: try conversationID(), senders: [:]))
        importer.extractionInjection = { if $0 == 1 { throw Boom() } }
        XCTAssertThrowsError(try importer.apply(plan3))
        XCTAssertEqual(mediaFileCount(), 2, "il file condiviso già in archivio deve restare")
    }

    /// Review Focus 5: annullare scollega gli allegati dai messaggi più vecchi, senza toccarli.
    func testUndoUnlinksAttachments() throws {
        var plain = ""
        for i in 1...3 { plain += Fixtures.line(t + Int64(i), "Ash", "\u{200E}immagine omessa") }
        try importNew(plain)
        let before = try dump(includeUndoneBatches: false)

        var rich = "", files: [(path: String, data: Data)] = []
        for i in 1...3 {
            let name = "0000000\(i)-PHOTO-x.jpg"
            rich += Fixtures.attach(t + Int64(i), "Ash", name)
            files.append((name, Fixtures.image(seed: i)))
        }
        let plan = try importer.analyze(try zipSource("z.zip", chat: rich, files: files),
                                        target: .existing(conversationID: try conversationID(), senders: [:]))
        try importer.apply(plan)
        XCTAssertEqual(mediaFileCount(), 3)

        try importer.undoLastImport(conversationID: try conversationID())
        XCTAssertEqual(try dump(includeUndoneBatches: false), before)
        XCTAssertEqual(try count("message"), 3)
        XCTAssertEqual(mediaFileCount(), 0)
    }

    /// Review Focus 1: molte voci, lette una alla volta, con avanzamento.
    func testManyEntriesStreaming() throws {
        var chat = "", files: [(path: String, data: Data)] = []
        for i in 0..<1500 {
            let name = String(format: "%08d-STICKER-x.webp", i)
            chat += Fixtures.attach(t + Int64(i), i % 2 == 0 ? "Ash" : "Io", name)
            files.append((name, Fixtures.bytes(i, count: 1024) + withUnsafeBytes(of: i) { Data($0) }))
        }
        let plan = try importer.analyze(try zipSource("grande.zip", chat: chat, files: files),
                                        target: .newConversation(title: "Ash", me: "Io"))
        XCTAssertEqual(plan.summary.stickers, 1500)
        var values: [Double] = []
        try importer.apply(plan) { values.append($0) }
        XCTAssertEqual(try count("attachment"), 1500)
        XCTAssertEqual(mediaFileCount(), 1500)
        XCTAssertEqual(values.last, 1.0)
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(values.count, 100)
    }

    func testZipWithoutChatFile() throws {
        let src = try zipSource("z.zip", chat: nil, files: [("foto.jpg", Fixtures.image(seed: 1))])
        XCTAssertThrowsError(try importer.suggest(src)) { XCTAssertEqual($0 as? ImportError, .noChatFile) }
        XCTAssertEqual(try count("conversation"), 0)
    }

    func testCorruptZip() throws {
        let url = try write("questo non è uno zip", name: "rotto.zip")
        XCTAssertThrowsError(try ZipSource(url: url)) {
            guard case .unreadable = $0 as? ImportError else { return XCTFail("errore inatteso: \($0)") }
        }
    }

    func testOrphanCleanupOnOpen() throws {
        let stray = store.media.url(forHash: String(repeating: "a", count: 64), ext: "jpg")
        try FileManager.default.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixtures.bytes(1).write(to: stray)
        try Fixtures.bytes(2).write(to: store.media.newStagingURL())
        let path = store.directory
        store = nil; importer = nil
        store = try ArchiveStore(directory: path)
        XCTAssertEqual(mediaFileCount(), 0)
        XCTAssertEqual(store.media.stagingFiles().count, 0)
    }

    func testThumbnail() throws {
        let url = dir.appendingPathComponent("grande.jpg")
        try Fixtures.image(seed: 4, size: 400).write(to: url)
        let thumb = try XCTUnwrap(Thumbnailer.thumbnail(for: url, kind: .photo, maxPixel: 100))
        XCTAssertEqual(max(thumb.width, thumb.height), 100)
        XCTAssertNil(Thumbnailer.thumbnail(for: dir.appendingPathComponent("assente.jpg"), kind: .photo, maxPixel: 100))
    }
}
