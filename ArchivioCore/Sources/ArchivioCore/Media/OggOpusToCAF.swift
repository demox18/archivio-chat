import Foundation

/// I messaggi vocali di WhatsApp sono Opus dentro un contenitore Ogg, che iOS
/// non sa riprodurre. Qui i pacchetti Opus vengono copiati così come sono in un
/// contenitore CAF, che iOS riproduce. L'audio non viene ricodificato.
public enum OggOpusToCAF {
    public enum ConversionError: Error { case notOgg, notOpus, empty }

    struct Parsed {
        var channels: Int
        var preSkip: Int
        var packets: [Data]
        var lastGranule: Int64
    }

    public static func convert(_ input: URL, to output: URL) throws {
        let parsed = try parse(try Data(contentsOf: input, options: .mappedIfSafe))
        try write(parsed).write(to: output, options: .atomic)
    }

    // MARK: - Lettura Ogg

    static func parse(_ data: Data) throws -> Parsed {
        let bytes = [UInt8](data)
        var offset = 0
        var packets: [Data] = []
        var current = Data()
        var lastGranule: Int64 = 0

        while offset + 27 <= bytes.count {
            guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                if packets.isEmpty && current.isEmpty { throw ConversionError.notOgg }
                break   // dati in coda non validi: si tiene ciò che è stato letto
            }
            var granule: UInt64 = 0
            for i in 0..<8 { granule |= UInt64(bytes[offset + 6 + i]) << (8 * UInt64(i)) }
            let segmentCount = Int(bytes[offset + 26])
            let tableStart = offset + 27
            guard tableStart + segmentCount <= bytes.count else { break }
            var cursor = tableStart + segmentCount
            for s in 0..<segmentCount {
                let length = Int(bytes[tableStart + s])
                guard cursor + length <= bytes.count else { break }
                current.append(contentsOf: bytes[cursor..<(cursor + length)])
                cursor += length
                if length < 255 {
                    packets.append(current)
                    current = Data()
                }
            }
            if granule != UInt64.max { lastGranule = Int64(bitPattern: granule) }
            offset = cursor
        }

        guard let head = packets.first, head.count >= 19,
              head.prefix(8) == Data("OpusHead".utf8) else { throw ConversionError.notOpus }
        let h = [UInt8](head)
        let channels = Int(h[9])
        let preSkip = Int(h[10]) | (Int(h[11]) << 8)
        var audio = Array(packets.dropFirst())
        if let tags = audio.first, tags.prefix(8) == Data("OpusTags".utf8) { audio.removeFirst() }
        audio.removeAll { $0.isEmpty }
        guard !audio.isEmpty, channels == 1 || channels == 2 else { throw ConversionError.empty }
        // Il decodificatore di iOS vuole un solo frame per pacchetto.
        let single = audio.flatMap(splitFrames(of:))
        guard !single.isEmpty else { throw ConversionError.empty }
        return Parsed(channels: channels, preSkip: preSkip, packets: single, lastGranule: lastGranule)
    }

    /// Divide un pacchetto Opus con più frame in pacchetti da un frame (RFC 6716, §3.2).
    /// Se il pacchetto non è interpretabile lo restituisce intatto.
    static func splitFrames(of packet: Data) -> [Data] {
        let b = [UInt8](packet)
        guard let toc = b.first else { return [] }
        let single = toc & 0xFC
        func make(_ range: Range<Int>) -> Data { Data([single] + b[range]) }
        /// Lunghezza di un frame codificata su uno o due byte.
        func length(at i: inout Int) -> Int? {
            guard i < b.count else { return nil }
            let first = Int(b[i]); i += 1
            if first < 252 { return first }
            guard i < b.count else { return nil }
            let second = Int(b[i]); i += 1
            return first + 4 * second
        }

        switch toc & 3 {
        case 0:
            return [packet]
        case 1:
            let body = b.count - 1
            guard body % 2 == 0 else { return [packet] }
            return [make(1..<(1 + body / 2)), make((1 + body / 2)..<b.count)]
        case 2:
            var i = 1
            guard let first = length(at: &i), i + first <= b.count else { return [packet] }
            return [make(i..<(i + first)), make((i + first)..<b.count)]
        default:
            guard b.count >= 2 else { return [packet] }
            let vbr = b[1] & 0x80 != 0, padded = b[1] & 0x40 != 0
            let count = Int(b[1] & 0x3F)
            guard count > 0 else { return [packet] }
            var i = 2
            var padding = 0
            if padded {
                while true {
                    guard i < b.count else { return [packet] }
                    let v = Int(b[i]); i += 1
                    if v == 255 { padding += 254 } else { padding += v; break }
                }
            }
            var lengths: [Int] = []
            if vbr {
                for _ in 0..<(count - 1) {
                    guard let l = length(at: &i) else { return [packet] }
                    lengths.append(l)
                }
                let rest = b.count - i - padding - lengths.reduce(0, +)
                guard rest >= 0 else { return [packet] }
                lengths.append(rest)
            } else {
                let rest = b.count - i - padding
                guard rest >= 0, rest % count == 0 else { return [packet] }
                lengths = Array(repeating: rest / count, count: count)
            }
            var out: [Data] = []
            for l in lengths {
                guard i + l <= b.count else { return [packet] }
                out.append(make(i..<(i + l)))
                i += l
            }
            return out
        }
    }

    /// Campioni a 48 kHz contenuti in un pacchetto Opus, dal suo primo byte (TOC).
    static func frameCount(of packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let perFrame: Int
        switch config {
        case 0..<12: perFrame = [480, 960, 1920, 2880][config % 4]
        case 12..<16: perFrame = [480, 960][config % 2]
        default: perFrame = [120, 240, 480, 960][config % 4]
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 0
        }
        return perFrame * frames
    }

    // MARK: - Scrittura CAF

    static func write(_ p: Parsed) -> Data {
        let frames = p.packets.map(frameCount(of:))
        let constant = Set(frames).count == 1
        let framesPerPacket = constant ? frames[0] : 0
        let total = Int64(frames.reduce(0, +))
        var valid = p.lastGranule > 0 ? p.lastGranule - Int64(p.preSkip) : total - Int64(p.preSkip)
        valid = max(0, min(valid, total - Int64(p.preSkip)))
        let remainder = max(0, total - Int64(p.preSkip) - valid)

        var out = Data()
        out.append(Data("caff".utf8)); out.be(UInt16(1)); out.be(UInt16(0))

        out.chunk("desc") { c in
            c.be(Double(48_000).bitPattern)
            c.append(Data("opus".utf8))
            c.be(UInt32(0))                       // flag
            c.be(UInt32(0))                       // byte per pacchetto: variabile
            c.be(UInt32(framesPerPacket))
            c.be(UInt32(p.channels))
            c.be(UInt32(0))                       // bit per canale
        }
        // Parametri del decodificatore, nella forma che scrive macOS.
        out.chunk("kuki") { c in
            c.be(UInt32(0x800))
            c.be(UInt32(48_000))
            c.be(UInt32(framesPerPacket == 0 ? 960 : framesPerPacket))
            c.be(Int32(-1000))
            c.be(UInt32(p.channels))
            c.be(UInt32(0)); c.be(UInt32(0))
        }
        out.chunk("chan") { c in
            c.be(UInt32(p.channels == 2 ? (101 << 16) | 2 : (100 << 16) | 1))
            c.be(UInt32(0)); c.be(UInt32(0))
        }
        out.chunk("pakt") { c in
            c.be(Int64(p.packets.count))
            c.be(valid)
            c.be(Int32(p.preSkip))
            c.be(Int32(remainder))
            for (packet, n) in zip(p.packets, frames) {
                c.varint(packet.count)
                if !constant { c.varint(n) }
            }
        }
        out.chunk("data") { c in
            c.be(UInt32(1))                       // contatore di modifiche
            for packet in p.packets { c.append(packet) }
        }
        return out
    }
}

private extension Data {
    mutating func be<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func chunk(_ type: String, _ build: (inout Data) -> Void) {
        var body = Data()
        build(&body)
        append(Data(type.utf8))
        be(Int64(body.count))
        append(body)
    }

    /// Intero a lunghezza variabile del formato CAF: 7 bit per byte, dal più significativo.
    mutating func varint(_ value: Int) {
        var groups: [UInt8] = [UInt8(value & 0x7F)]
        var v = value >> 7
        while v > 0 { groups.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        append(contentsOf: groups.reversed())
    }
}
