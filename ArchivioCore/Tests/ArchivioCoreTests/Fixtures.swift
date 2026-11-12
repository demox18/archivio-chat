import Foundation
import XCTest
@testable import ArchivioCore

/// Dati inventati per i test, nel formato reale delle esportazioni iPhone.
enum Fixtures {
    /// Istante di partenza: 1 gennaio 2024, 10:00:00 (componenti locali).
    static let start: Int64 = 1_704_103_200

    static func stamp(_ ts: Int64) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                   from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "[%02d/%02d/%02d, %02d:%02d:%02d]",
                      c.day!, c.month!, c.year! % 100, c.hour!, c.minute!, c.second!)
    }

    static func line(_ ts: Int64, _ sender: String, _ body: String) -> String {
        "\(stamp(ts)) \(sender): \(body)\r\n"
    }

    /// `count` messaggi a partire dall'indice `from`, uno ogni `step` secondi,
    /// alternando i mittenti. Il testo dipende solo dall'indice.
    static func makeChat(from: Int = 0, count: Int, senders: [String] = ["Io", "Ash"],
                         step: Int64 = 60, start: Int64 = Fixtures.start) -> String {
        var out = ""
        for i in from..<(from + count) {
            out += line(start + Int64(i) * step, senders[i % senders.count], "messaggio numero \(i)")
        }
        return out
    }

    static func data(_ s: String) -> Data { Data(s.utf8) }
}

class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archivio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ text: String, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
}
