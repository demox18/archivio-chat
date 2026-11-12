import Foundation

/// Trasforma il testo di un'esportazione WhatsApp (formato iPhone) in messaggi.
///
/// Regola di fondo: nessuna riga viene scartata. Ciò che non è un'intestazione
/// valida continua il messaggio precedente; ciò che precede la prima
/// intestazione diventa un messaggio di servizio.
public enum ChatParser {
    private static let lrm: Character = "\u{200E}"

    private struct Header {
        var a: Int, b: Int, year: Int
        var hour: Int, minute: Int, second: Int
        var rest: Substring
    }

    private struct Raw {
        var header: Header
        var lines: [Substring]   // prima riga = resto dell'intestazione
        var line: Int
    }

    public static func parse(_ data: Data) -> ParseResult {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if text.isEmpty { return ParseResult(messages: [], unrecognizedLines: 0, senders: []) }
        if text.hasSuffix("\n") { text.removeLast() }

        var raws: [Raw] = []
        var leading: [Substring] = []
        var sawFirstFieldOver12 = false, sawSecondFieldOver12 = false

        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            if let h = parseHeader(line) {
                if h.a > 12 { sawFirstFieldOver12 = true }
                if h.b > 12 { sawSecondFieldOver12 = true }
                raws.append(Raw(header: h, lines: [h.rest], line: lineNumber))
            } else if raws.isEmpty {
                leading.append(line)
            } else {
                raws[raws.count - 1].lines.append(line)
            }
        }

        let monthFirst = sawSecondFieldOver12 && !sawFirstFieldOver12
        var messages: [ParsedMessage] = []
        messages.reserveCapacity(raws.count + 1)
        var senders: [String] = []
        var seen = Set<String>()

        for raw in raws {
            let h = raw.header
            let day = monthFirst ? h.b : h.a
            let month = monthFirst ? h.a : h.b
            let ts = daysFromCivil(year: h.year, month: month, day: day) * 86_400
                + Int64(h.hour) * 3600 + Int64(h.minute) * 60 + Int64(h.second)
            let (sender, firstBody) = splitSender(raw.lines[0])
            var bodyLines = [firstBody]
            bodyLines.append(contentsOf: raw.lines.dropFirst())
            let body = bodyLines.joined(separator: "\n")
            var m = classify(body: body, hasSender: sender != nil)
            m.ts = ts; m.sender = sender; m.line = raw.line
            messages.append(m)
            if let s = sender, seen.insert(s).inserted { senders.append(s) }
        }

        if !leading.isEmpty {
            let ts = messages.first?.ts ?? 0
            let body = leading.joined(separator: "\n").filter { $0 != lrm }
            messages.insert(ParsedMessage(ts: ts, sender: nil, kind: .system, text: body, line: 1), at: 0)
        }
        return ParseResult(messages: messages, unrecognizedLines: leading.count, senders: senders)
    }

    // MARK: - Intestazione

    /// `[gg/mm/aa, hh:mm:ss] resto`, con secondi e AM/PM facoltativi.
    private static func parseHeader(_ line: Substring) -> Header? {
        var s = line
        while s.first == lrm { s = s.dropFirst() }
        guard s.first == "[", let close = s.firstIndex(of: "]") else { return nil }
        let inner = s[s.index(after: s.startIndex)..<close]
        guard inner.count <= 32, let comma = inner.firstIndex(of: ",") else { return nil }

        let dateParts = inner[..<comma].split(separator: "/", omittingEmptySubsequences: false)
        guard dateParts.count == 3,
              let a = strictInt(dateParts[0], maxDigits: 2),
              let b = strictInt(dateParts[1], maxDigits: 2),
              var year = strictInt(dateParts[2], maxDigits: 4),
              (1...31).contains(a), (1...31).contains(b), a <= 12 || b <= 12
        else { return nil }
        if dateParts[2].count <= 2 { year += 2000 }

        var timePart = inner[inner.index(after: comma)...]
        guard timePart.first == " " else { return nil }
        timePart = timePart.dropFirst()
        var pm: Bool? = nil
        let upper = timePart.uppercased()
        if upper.hasSuffix("AM") || upper.hasSuffix("PM") {
            pm = upper.hasSuffix("PM")
            timePart = timePart.dropLast(2)
            while let last = timePart.last, last == " " || last == "\u{202F}" || last == "\u{00A0}" {
                timePart = timePart.dropLast()
            }
        }
        let t = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard t.count == 2 || t.count == 3,
              var hour = strictInt(t[0], maxDigits: 2),
              let minute = strictInt(t[1], maxDigits: 2), t[1].count == 2,
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        var second = 0
        if t.count == 3 {
            guard let sec = strictInt(t[2], maxDigits: 2), t[2].count == 2, (0...59).contains(sec) else { return nil }
            second = sec
        }
        if let pm {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (pm ? 12 : 0)
        }

        var rest = s[s.index(after: close)...]
        if rest.first == " " { rest = rest.dropFirst() } else if !rest.isEmpty { return nil }
        return Header(a: a, b: b, year: year, hour: hour, minute: minute, second: second, rest: rest)
    }

    private static func strictInt(_ s: Substring, maxDigits: Int) -> Int? {
        guard !s.isEmpty, s.count <= maxDigits, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    /// Giorni dal 1° gennaio 1970 (calendario gregoriano).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int64 {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = Int64((month + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Divide `Mittente: testo`. Senza mittente restituisce `nil`.
    private static func splitSender(_ rest: Substring) -> (String?, Substring) {
        if let r = rest.range(of: ": ") {
            return (clean(rest[..<r.lowerBound]), rest[r.upperBound...])
        }
        if rest.hasSuffix(":") {
            return (clean(rest.dropLast()), "")
        }
        return (nil, rest)
    }

    private static func clean(_ s: Substring) -> String {
        String(s.filter { $0 != lrm })
    }

    // MARK: - Tipo del messaggio

    private static func classify(body: String, hasSender: Bool) -> ParsedMessage {
        let startsWithMark = body.first == lrm
        var text = body.filter { $0 != lrm }
        var edited = false

        for marker in Dialect.editedMarkers where text.hasSuffix(marker) {
            text.removeLast(marker.count)
            text = trimTrailing(text)
            edited = true
        }

        guard hasSender else {
            return ParsedMessage(ts: 0, sender: nil, kind: .system, text: text, edited: edited, line: 0)
        }

        if let (name, remainder) = extractAttachment(from: text) {
            return ParsedMessage(ts: 0, sender: nil, kind: Dialect.kind(forAttachmentNamed: name),
                                 text: remainder, attachmentName: name, edited: edited, line: 0)
        }

        let lowered = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let kind = Dialect.omitted[lowered] {
            return ParsedMessage(ts: 0, sender: nil, kind: kind, text: "", edited: edited, line: 0)
        }
        if Dialect.deleted.contains(lowered) {
            return ParsedMessage(ts: 0, sender: nil, kind: .deleted, text: text, edited: edited, line: 0)
        }
        if startsWithMark {
            let isCall = Dialect.callPrefixes.contains { lowered.hasPrefix($0) }
            return ParsedMessage(ts: 0, sender: nil, kind: isCall ? .call : .system,
                                 text: text, edited: edited, line: 0)
        }
        return ParsedMessage(ts: 0, sender: nil, kind: .text, text: text, edited: edited, line: 0)
    }

    /// Cerca `<allegato: nome>` e restituisce il nome e il testo restante (didascalia).
    private static func extractAttachment(from text: String) -> (String, String)? {
        for tag in Dialect.attachmentTags {
            guard let open = text.range(of: "<\(tag): "),
                  let close = text.range(of: ">", range: open.upperBound..<text.endIndex)
            else { continue }
            let name = String(text[open.upperBound..<close.lowerBound])
            guard !name.isEmpty, !name.contains("\n") else { continue }
            var remainder = text
            remainder.removeSubrange(open.lowerBound..<close.upperBound)
            return (name, remainder.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func trimTrailing(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, last == " " || last == "\t" { out = out.dropLast() }
        return String(out)
    }
}
