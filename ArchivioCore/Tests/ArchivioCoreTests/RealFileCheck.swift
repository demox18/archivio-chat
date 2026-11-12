import XCTest
@testable import ArchivioCore

/// Verifica locale sui file veri: gira solo se ARCHIVIO_REAL_TXT indica un file.
/// Stampa soltanto conteggi, mai il contenuto.
final class RealFileCheck: XCTestCase {
    func testCounts() throws {
        guard let path = ProcessInfo.processInfo.environment["ARCHIVIO_REAL_TXT"] else {
            throw XCTSkip("nessun file vero indicato")
        }
        let t0 = Date()
        let r = ChatParser.parse(try Data(contentsOf: URL(fileURLWithPath: path)))
        var kinds: [MessageKind: Int] = [:]
        var named = 0
        for m in r.messages { kinds[m.kind, default: 0] += 1; if m.attachmentName != nil { named += 1 } }
        print("REAL messages=\(r.messages.count) unrecognized=\(r.unrecognizedLines) senders=\(r.senders.count) named=\(named) edited=\(r.messages.filter(\.edited).count) secs=\(Date().timeIntervalSince(t0))")
        print("REAL kinds=\(kinds.map { "\($0.key.rawValue):\($0.value)" }.sorted())")
    }
}
