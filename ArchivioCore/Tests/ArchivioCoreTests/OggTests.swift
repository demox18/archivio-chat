import XCTest
import AudioToolbox
@testable import ArchivioCore

final class OggTests: TempDirTestCase {
    /// Una pagina Ogg con i segmenti indicati (il CRC non viene controllato dal lettore).
    private func page(granule: UInt64, segments: [Data]) -> Data {
        var d = Data("OggS".utf8)
        d.append(contentsOf: [0, 0])
        withUnsafeBytes(of: granule.littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: [UInt8](repeating: 0, count: 12))   // serie, sequenza, CRC
        d.append(UInt8(segments.count))
        for s in segments { d.append(UInt8(s.count)) }
        for s in segments { d.append(s) }
        return d
    }

    private var opusHead: Data {
        var d = Data("OpusHead".utf8)
        d.append(contentsOf: [1, 1, 0x38, 0x01])           // versione, 1 canale, pre-skip 312
        d.append(contentsOf: [0x80, 0x3E, 0, 0, 0, 0, 0])  // 16 kHz, guadagno, mappa
        return d
    }

    /// Pacchetto da un frame di 20 ms (configurazione 1, codice 0).
    private func frame(_ size: Int, fill: UInt8) -> Data { Data([0x08] + [UInt8](repeating: fill, count: size - 1)) }

    func testPageParsing() throws {
        let a = frame(300, fill: 0xAA)      // 300 byte: 255 + 45, a cavallo di due pagine
        let b = frame(11, fill: 0xBB)
        var ogg = page(granule: 0, segments: [opusHead])
        ogg.append(page(granule: 0, segments: [Data("OpusTags".utf8) + Data(count: 8)]))
        ogg.append(page(granule: UInt64.max, segments: [a.prefix(255)]))
        ogg.append(page(granule: 312 + 1920, segments: [a.suffix(45), b]))

        let parsed = try OggOpusToCAF.parse(ogg)
        XCTAssertEqual(parsed.channels, 1)
        XCTAssertEqual(parsed.preSkip, 312)
        XCTAssertEqual(parsed.packets, [a, b])
        XCTAssertEqual(parsed.lastGranule, 312 + 1920)

        let input = dir.appendingPathComponent("v.opus"), output = dir.appendingPathComponent("v.caf")
        try ogg.write(to: input)
        try OggOpusToCAF.convert(input, to: output)

        var file: AudioFileID?
        XCTAssertEqual(AudioFileOpenURL(output as CFURL, .readPermission, 0, &file), noErr)
        var count: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        XCTAssertEqual(AudioFileGetProperty(file!, kAudioFilePropertyAudioDataPacketCount, &size, &count), noErr)
        XCTAssertEqual(count, 2)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        XCTAssertEqual(AudioFileGetProperty(file!, kAudioFilePropertyDataFormat, &size, &format), noErr)
        XCTAssertEqual(format.mFormatID, kAudioFormatOpus)
        XCTAssertEqual(format.mFramesPerPacket, 960)
        AudioFileClose(file!)
    }

    func testSplitFrames() {
        // codice 0: resta com'è
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x08, 1, 2])), [Data([0x08, 1, 2])])
        // codice 1: due frame uguali
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x09, 1, 2, 3, 4])), [Data([0x08, 1, 2]), Data([0x08, 3, 4])])
        // codice 2: primo frame di lunghezza dichiarata
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x0A, 1, 9, 7, 7])), [Data([0x08, 9]), Data([0x08, 7, 7])])
        // codice 3, lunghezze variabili, 3 frame: 1, 2 e il resto
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x0B, 0x83, 1, 2, 5, 6, 6, 7, 7, 7])),
                       [Data([0x08, 5]), Data([0x08, 6, 6]), Data([0x08, 7, 7, 7])])
        // codice 3, lunghezze uguali con 2 byte di riempimento
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x0B, 0x42, 2, 1, 1, 2, 2, 0, 0])),
                       [Data([0x08, 1, 1]), Data([0x08, 2, 2])])
        // pacchetto troncato: restituito intatto, mai un errore
        XCTAssertEqual(OggOpusToCAF.splitFrames(of: Data([0x0B, 0x83, 200])), [Data([0x0B, 0x83, 200])])
        XCTAssertEqual(OggOpusToCAF.frameCount(of: Data([0x08, 0])), 960)
    }

    func testRejectsNonOgg() {
        XCTAssertThrowsError(try OggOpusToCAF.parse(Data("non sono un audio".utf8)))
        XCTAssertThrowsError(try OggOpusToCAF.parse(Data()))
    }
}
