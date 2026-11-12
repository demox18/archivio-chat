import XCTest
import AVFoundation
@testable import ArchivioCore

/// Verifica locale: converte i vocali veri della cartella ARCHIVIO_REAL_OPUS_DIR
/// e controlla che il sistema li apra e li decodifichi. Stampa solo numeri.
final class RealAudioCheck: XCTestCase {
    func testConvertAll() throws {
        guard let dir = ProcessInfo.processInfo.environment["ARCHIVIO_REAL_OPUS_DIR"] else { throw XCTSkip("nessuna cartella") }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "opus" }
        var ok = 0, bad = 0; var frameKinds = Set<Int>(); var total = 0.0
        for f in files {
            let out = f.deletingPathExtension().appendingPathExtension("caf")
            do {
                let p = try OggOpusToCAF.parse(try Data(contentsOf: f))
                p.packets.forEach { frameKinds.insert(OggOpusToCAF.frameCount(of: $0)) }
                try OggOpusToCAF.convert(f, to: out)
                let af = try AVAudioFile(forReading: out)
                let buf = AVAudioPCMBuffer(pcmFormat: af.processingFormat, frameCapacity: 48000)!
                try af.read(into: buf)
                guard af.length > 0, buf.frameLength > 0 else { bad += 1; continue }
                total += Double(af.length) / af.fileFormat.sampleRate
                ok += 1
            } catch { bad += 1; print("REALAUDIO errore:", type(of: error), error) }
        }
        print("REALAUDIO ok=\(ok) bad=\(bad) frameKinds=\(frameKinds.sorted()) secondiTotali=\(Int(total))")
        XCTAssertEqual(bad, 0)
    }
}
