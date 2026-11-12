import Foundation

/// Il confronto tra ciò che è già in archivio e ciò che arriva da un file.
/// Funzione pura: non legge e non scrive nulla.
///
/// Principio: un messaggio in arrivo è "già presente" solo quando la
/// corrispondenza è certa. In ogni altro caso viene aggiunto.
enum Merger {
    struct Existing: Equatable {
        var id: Int64
        var ts: Int64
        var participantKey: Int64
        var kind: MessageKind
        var text: String
        var attachmentName: String?
        var hasFile: Bool
        var edited: Bool
    }

    struct Incoming: Equatable {
        var ts: Int64
        var participantKey: Int64
        var kind: MessageKind
        var text: String
        var attachmentName: String?
        var sourceHasFile: Bool
        var edited: Bool
    }

    enum Decision: Equatable, Sendable {
        /// È lo stesso messaggio: non si fa nulla.
        case present(existingID: Int64)
        /// È lo stesso messaggio e il file porta il suo allegato: lo si collega.
        case link(existingID: Int64)
        /// Messaggio nuovo, eventualmente segnato come possibile doppione.
        case insert(possibleDuplicate: Bool)
    }

    private struct GroupKey: Hashable { let ts: Int64; let who: Int64 }

    static func decide(existing: [Existing], incoming: [Incoming]) -> [Decision] {
        var decisions = [Decision](repeating: .insert(possibleDuplicate: false), count: incoming.count)
        guard !existing.isEmpty else { return decisions }

        var existingGroups: [GroupKey: [Existing]] = [:]
        for e in existing { existingGroups[GroupKey(ts: e.ts, who: e.participantKey), default: []].append(e) }
        var incomingGroups: [GroupKey: [Int]] = [:]
        for (i, m) in incoming.enumerated() { incomingGroups[GroupKey(ts: m.ts, who: m.participantKey), default: []].append(i) }

        for (key, indices) in incomingGroups {
            guard let group = existingGroups[key] else { continue }
            decideGroup(existing: group, incoming: incoming, indices: indices, into: &decisions)
        }
        return decisions
    }

    /// Stesso secondo e stesso mittente.
    private static func decideGroup(existing: [Existing], incoming: [Incoming], indices: [Int],
                                    into decisions: inout [Decision]) {
        var used = [Bool](repeating: false, count: existing.count)

        func firstFree(_ match: (Existing) -> Bool) -> Int? {
            existing.indices.first { !used[$0] && match(existing[$0]) }
        }

        // 1. Non media: tipo e testo identici, contando le ripetizioni.
        var leftover: [Int] = []
        for i in indices where !incoming[i].kind.isMedia {
            let m = incoming[i]
            let text = normalize(m.text)
            if let e = firstFree({ $0.kind == m.kind && normalize($0.text) == text }) {
                used[e] = true
                decisions[i] = .present(existingID: existing[e].id)
            } else {
                leftover.append(i)
            }
        }

        // 2. Media. Prima i nomi uguali, poi i segnaposto, sempre in ordine.
        let media = indices.filter { incoming[$0].kind.isMedia }
        var unmatchedMedia: [Int] = []
        // (a) stesso nome di file
        for i in media {
            let m = incoming[i]
            guard let name = m.attachmentName,
                  let e = firstFree({ $0.kind == m.kind && $0.attachmentName == name }) else {
                unmatchedMedia.append(i); continue
            }
            used[e] = true
            decisions[i] = (!existing[e].hasFile && m.sourceHasFile)
                ? .link(existingID: existing[e].id) : .present(existingID: existing[e].id)
        }
        // (b) in arrivo con nome ↔ segnaposto omesso in archivio
        var stillUnmatched: [Int] = []
        for i in unmatchedMedia {
            let m = incoming[i]
            guard m.attachmentName != nil,
                  let e = firstFree({ $0.kind == m.kind && $0.attachmentName == nil }) else {
                stillUnmatched.append(i); continue
            }
            used[e] = true
            decisions[i] = m.sourceHasFile ? .link(existingID: existing[e].id) : .present(existingID: existing[e].id)
        }
        // (c) in arrivo omesso ↔ qualunque media dello stesso tipo non ancora abbinato
        for i in stillUnmatched {
            let m = incoming[i]
            guard m.attachmentName == nil, let e = firstFree({ $0.kind == m.kind }) else { continue }
            used[e] = true
            decisions[i] = .present(existingID: existing[e].id)
        }
        // (d) il resto resta .insert(false)

        // 3. Possibili doppioni tra i non media rimasti: si aggiungono comunque.
        for i in leftover {
            let m = incoming[i]
            let loose = looseKey(m.text)
            let suspicious = existing.indices.contains { e in
                !used[e] && existing[e].kind == m.kind
                    && (looseKey(existing[e].text) == loose || m.edited || existing[e].edited)
            }
            decisions[i] = .insert(possibleDuplicate: suspicious)
        }
    }

    /// Testo per il confronto certo: senza spazi e a capo in coda.
    static func normalize(_ s: String) -> String {
        var out = Substring(s)
        while let last = out.last, last.isWhitespace { out = out.dropLast() }
        return String(out)
    }

    /// Testo per il confronto "simile": minuscolo, spazi ripetuti ridotti a uno.
    static func looseKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
