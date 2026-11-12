import Foundation
import GRDB

/// Importazione in due fasi: `analyze` non scrive nulla e produce l'anteprima;
/// `apply` scrive tutto in una sola transazione, oppure niente.
public final class Importer: @unchecked Sendable {
    private let store: ArchiveStore

    /// Solo per i test: chiamata ogni 100 messaggi scritti, dentro la transazione.
    var failureInjection: ((_ step: Int) throws -> Void)?
    /// Solo per i test: chiamata prima di estrarre ogni allegato.
    var extractionInjection: ((_ index: Int) throws -> Void)?

    public init(store: ArchiveStore) {
        self.store = store
    }

    // MARK: - Proposta della destinazione

    public func suggest(_ source: any ImportSource) throws -> TargetSuggestion {
        let parsed = ChatParser.parse(try source.chatText())
        guard !parsed.messages.isEmpty else { throw ImportError.noMessages }
        let senders = parsed.senders

        let (matched, likelyMe) = try store.db.read { db -> (Int64?, String?) in
            var votes: [Int64: Int] = [:]
            var me: String?
            for name in senders {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT a.conversation_id AS c, p.is_me AS me
                    FROM participant_alias a JOIN participant p ON p.id = a.participant_id
                    WHERE a.name = ?
                    """, arguments: [name])
                for row in rows {
                    if (row["me"] as Int) == 1 { me = me ?? name } else { votes[row["c"], default: 0] += 1 }
                }
            }
            // La conversazione che conosce più mittenti; a parità, la più recente.
            let best = votes.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
            return (best, me)
        }

        return TargetSuggestion(senders: senders, matchedConversationID: matched,
                                suggestedTitle: Self.title(fromFileName: source.displayName, senders: senders, me: likelyMe),
                                likelyMe: likelyMe, messageCount: parsed.messages.count)
    }

    static func title(fromFileName name: String, senders: [String], me: String?) -> String {
        var base = (name as NSString).deletingPathExtension
        for prefix in ["WhatsApp Chat - ", "WhatsApp Chat with ", "Chat WhatsApp con ", "Chat WhatsApp - "]
        where base.hasPrefix(prefix) {
            base.removeFirst(prefix.count)
        }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty || base == "_chat" {
            return senders.first { $0 != me } ?? senders.first ?? "Chat"
        }
        return base
    }

    // MARK: - Analisi

    public func analyze(_ source: any ImportSource, target: ImportTarget) throws -> ImportPlan {
        let parsed = ChatParser.parse(try source.chatText())
        guard !parsed.messages.isEmpty else { throw ImportError.noMessages }
        let fileHash = try source.fileHash()
        let available = Set(source.attachmentNames)
        let minTS = parsed.messages.map(\.ts).min()!
        let maxTS = parsed.messages.map(\.ts).max()!

        var keyForSender: [String: Int64] = [:]
        var newParticipants: [ImportPlan.NewParticipant] = []
        var aliasAdds: [(name: String, participantID: Int64)] = []
        var existing: [Merger.Existing] = []
        var snapshot: ImportPlan.Snapshot?

        func addNew(_ name: String, isMe: Bool) {
            newParticipants.append(.init(name: name, isMe: isMe))
            keyForSender[name] = -Int64(newParticipants.count)
        }

        switch target {
        case .newConversation(_, let me):
            for name in parsed.senders { addNew(name, isMe: name == me) }

        case .existing(let conversationID, let choices):
            try store.db.read { db in
                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation WHERE id = ?", arguments: [conversationID]) == 1
                else { throw ImportError.conversationNotFound }

                var aliases: [String: Int64] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT name, participant_id FROM participant_alias WHERE conversation_id = ?",
                                            arguments: [conversationID]) {
                    aliases[row["name"]] = row["participant_id"]
                }
                let participants = Set(try Int64.fetchAll(db, sql: "SELECT id FROM participant WHERE conversation_id = ?",
                                                          arguments: [conversationID]))
                for name in parsed.senders {
                    if let known = aliases[name] {
                        // Un nome già noto resta legato al suo partecipante: non si rimappa.
                        keyForSender[name] = known
                    } else if let choice = choices[name] {
                        switch choice {
                        case .existing(let pid):
                            guard participants.contains(pid) else { throw ImportError.invalidParticipant }
                            keyForSender[name] = pid
                            aliasAdds.append((name, pid))
                        case .new(let isMe):
                            addNew(name, isMe: isMe)
                        }
                    } else {
                        addNew(name, isMe: false)
                    }
                }

                snapshot = try Self.snapshot(db, conversationID: conversationID)

                // Regola delle date: si confronta solo dove gli intervalli si sovrappongono.
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT m.id, m.ts, m.participant_id, m.kind, m.text, m.edited,
                           COALESCE(m.attachment_name, (SELECT file_name FROM attachment a WHERE a.message_id = m.id LIMIT 1)) AS name,
                           EXISTS(SELECT 1 FROM attachment a WHERE a.message_id = m.id) AS has_file
                    FROM message m
                    WHERE m.conversation_id = ? AND m.ts BETWEEN ? AND ?
                    ORDER BY m.ts, m.batch_id, m.seq
                    """, arguments: [conversationID, minTS, maxTS])
                while let row = try rows.next() {
                    existing.append(Merger.Existing(
                        id: row["id"], ts: row["ts"], participantKey: (row["participant_id"] as Int64?) ?? 0,
                        kind: MessageKind(rawValue: row["kind"]) ?? .text, text: row["text"],
                        attachmentName: row["name"], hasFile: row["has_file"], edited: row["edited"]))
                }
            }
        }

        let participantKeys: [Int64] = parsed.messages.map { m in m.sender.flatMap { keyForSender[$0] } ?? 0 }
        let incoming: [Merger.Incoming] = zip(parsed.messages, participantKeys).map { m, key in
            Merger.Incoming(ts: m.ts, participantKey: key, kind: m.kind, text: m.text,
                            attachmentName: m.attachmentName,
                            sourceHasFile: m.attachmentName.map(available.contains) ?? false,
                            edited: m.edited)
        }
        let decisions = Merger.decide(existing: existing, incoming: incoming)
        let existingHasFile = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0.hasFile) })

        var s = ImportSummary()
        s.totalInFile = parsed.messages.count
        s.unrecognizedLines = parsed.unrecognizedLines
        s.overlaps = !existing.isEmpty
        s.newParticipants = newParticipants.map(\.name)
        s.firstTS = minTS
        s.lastTS = maxTS
        for (m, d) in zip(incoming, decisions) {
            switch d {
            case .present(let id):
                s.alreadyPresent += 1
                if m.attachmentName != nil, !m.sourceHasFile, existingHasFile[id] == false { s.missingAttachments += 1 }
            case .link:
                s.alreadyPresent += 1
                s.attachmentsToLink += 1
            case .insert(let dup):
                s.newMessages += 1
                if dup { s.possibleDuplicates += 1 }
                if m.attachmentName != nil, !m.sourceHasFile { s.missingAttachments += 1 }
            }
            if m.attachmentName != nil, m.sourceHasFile {
                switch m.kind {
                case .photo: s.photos += 1
                case .video, .gif: s.videos += 1
                case .sticker: s.stickers += 1
                case .audio: s.audios += 1
                default: s.documents += 1
                }
            }
        }

        return ImportPlan(summary: s, fileName: source.displayName, source: source, fileHash: fileHash,
                          target: target, messages: parsed.messages, decisions: decisions,
                          participantKeys: participantKeys, newParticipants: newParticipants,
                          aliasAdds: aliasAdds, snapshot: snapshot)
    }

    private static func snapshot(_ db: Database, conversationID: Int64) throws -> ImportPlan.Snapshot {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(MAX(id), 0) AS m,
                   (SELECT COUNT(*) FROM attachment a JOIN message x ON x.id = a.message_id WHERE x.conversation_id = ?1) AS a
            FROM message WHERE conversation_id = ?1
            """, arguments: [conversationID])!
        return .init(messages: row["n"], maxMessageID: row["m"], attachments: row["a"])
    }

    // MARK: - Applicazione

    private struct StoredFile { let hash: String; let size: Int64; let playable: String? }

    /// Scrive l'importazione. Restituisce l'identificativo dell'importazione.
    @discardableResult
    public func apply(_ plan: ImportPlan, progress: ((Double) -> Void)? = nil) throws -> Int64 {
        // Gli allegati che servono davvero: quelli di messaggi nuovi o da collegare.
        var wanted: [Int] = []
        for (i, m) in plan.messages.enumerated() where m.attachmentName != nil {
            switch plan.decisions[i] {
            case .present: continue
            case .link, .insert: wanted.append(i)
            }
        }
        let available = Set(plan.source.attachmentNames)
        wanted = wanted.filter { available.contains(plan.messages[$0].attachmentName!) }

        let needed = wanted.reduce(Int64(0)) { $0 + plan.source.attachmentSize(named: plan.messages[$1].attachmentName!) }
        if needed > 0,
           let free = try? store.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0, free < needed + 200_000_000 {
            throw ImportError.notEnoughSpace(needed: needed + 200_000_000)
        }

        // Fase 1: i file. Finché il database non li cita, non sono visibili;
        // se qualcosa va storto si cancellano quelli appena creati.
        var createdFiles: [URL] = []
        var stored: [Int: StoredFile] = [:]
        var byName: [String: StoredFile] = [:]
        let fm = FileManager.default
        func rollbackFiles() {
            for url in createdFiles { try? fm.removeItem(at: url) }
            store.media.clearStaging()
        }

        do {
            for (n, i) in wanted.enumerated() {
                try extractionInjection?(n)
                let m = plan.messages[i]
                let name = m.attachmentName!
                if let already = byName[name] { stored[i] = already; continue }
                let ext = (name as NSString).pathExtension.lowercased()
                let tmp = store.media.newStagingURL()
                try plan.source.extractAttachment(named: name, to: tmp)
                let r = try store.media.ingest(fileAt: tmp, ext: ext)
                if !r.existed { createdFiles.append(store.media.url(forHash: r.hash, ext: ext)) }

                var playable: String?
                if m.kind == .audio, ["opus", "ogg"].contains(ext) {
                    let caf = store.media.url(forHash: r.hash, ext: "caf")
                    if fm.fileExists(atPath: caf.path) {
                        playable = r.hash
                    } else if (try? OggOpusToCAF.convert(store.media.url(forHash: r.hash, ext: ext), to: caf)) != nil {
                        playable = r.hash
                        createdFiles.append(caf)
                    } else {
                        try? fm.removeItem(at: caf)
                    }
                }
                let file = StoredFile(hash: r.hash, size: r.size, playable: playable)
                stored[i] = file
                byName[name] = file
                progress?(0.9 * Double(n + 1) / Double(wanted.count))
            }
        } catch {
            rollbackFiles()
            throw error
        }

        // Fase 2: il database, in una sola transazione.
        do {
            let batchID = try store.db.write { db in try self.write(plan, stored: stored, db: db) }
            progress?(1.0)
            return batchID
        } catch {
            rollbackFiles()
            throw error
        }
    }

    private func write(_ plan: ImportPlan, stored: [Int: StoredFile], db: Database) throws -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let conversationID: Int64
        var createdConversation = false

        switch plan.target {
        case .newConversation(let title, _):
            try db.execute(sql: "INSERT INTO conversation(title, created_at) VALUES (?, ?)", arguments: [title, now])
            conversationID = db.lastInsertedRowID
            createdConversation = true
        case .existing(let id, _):
            conversationID = id
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation WHERE id = ?", arguments: [id]) == 1 else {
                throw ImportError.conversationNotFound
            }
            // Se l'archivio è cambiato dopo l'analisi, le decisioni non valgono più.
            guard try Self.snapshot(db, conversationID: id) == plan.snapshot else { throw ImportError.archiveChanged }
        }

        try db.execute(sql: """
            INSERT INTO import_batch(conversation_id, file_name, file_hash, created_at, status, created_conversation, summary_json)
            VALUES (?, ?, ?, ?, 'applied', ?, ?)
            """, arguments: [conversationID, plan.fileName, plan.fileHash, now, createdConversation,
                             String(decoding: try JSONEncoder().encode(plan.summary), as: UTF8.self)])
        let batchID = db.lastInsertedRowID

        var newIDs: [Int64] = []
        for p in plan.newParticipants {
            try db.execute(sql: "INSERT INTO participant(conversation_id, display_name, is_me, created_by_batch) VALUES (?, ?, ?, ?)",
                           arguments: [conversationID, p.name, p.isMe, batchID])
            let pid = db.lastInsertedRowID
            newIDs.append(pid)
            try db.execute(sql: "INSERT INTO participant_alias(conversation_id, participant_id, name, created_by_batch) VALUES (?, ?, ?, ?)",
                           arguments: [conversationID, pid, p.name, batchID])
        }
        for alias in plan.aliasAdds {
            try db.execute(sql: "INSERT INTO participant_alias(conversation_id, participant_id, name, created_by_batch) VALUES (?, ?, ?, ?)",
                           arguments: [conversationID, alias.participantID, alias.name, batchID])
        }

        let insertMessage = try db.makeStatement(sql: """
            INSERT INTO message(conversation_id, participant_id, ts, kind, text, attachment_name, edited,
                                possible_duplicate, batch_id, source_line, seq)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        let insertAttachment = try db.makeStatement(sql: """
            INSERT INTO attachment(message_id, file_name, sha256, byte_size, kind, playable_hash, batch_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """)

        func attach(_ index: Int, to messageID: Int64) throws {
            guard let file = stored[index], let name = plan.messages[index].attachmentName else { return }
            try insertAttachment.execute(arguments: [messageID, name, file.hash, file.size,
                                                     plan.messages[index].kind.rawValue, file.playable, batchID])
        }

        var written = 0
        for (i, m) in plan.messages.enumerated() {
            switch plan.decisions[i] {
            case .present:
                continue
            case .link(let existingID):
                try attach(i, to: existingID)
            case .insert(let possibleDuplicate):
                let key = plan.participantKeys[i]
                let participantID: Int64? = key > 0 ? key : (key < 0 ? newIDs[Int(-key) - 1] : nil)
                try insertMessage.execute(arguments: [conversationID, participantID, m.ts, m.kind.rawValue, m.text,
                                                      m.attachmentName, m.edited, possibleDuplicate, batchID, m.line, i])
                try attach(i, to: db.lastInsertedRowID)
                written += 1
                if written % 100 == 0 { try failureInjection?(written / 100) }
            }
        }
        return batchID
    }

    // MARK: - Annullamento

    /// L'ultima importazione annullabile della conversazione e quante stelle andrebbero perse.
    public func canUndo(conversationID: Int64) throws -> (batchID: Int64, starsLost: Int)? {
        try store.db.read { db in
            guard let batchID = try Self.lastApplied(db, conversationID: conversationID) else { return nil }
            let stars = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM star s JOIN message m ON m.id = s.message_id WHERE m.batch_id = ?
                """, arguments: [batchID])!
            return (batchID, stars)
        }
    }

    private static func lastApplied(_ db: Database, conversationID: Int64) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT id FROM import_batch WHERE conversation_id = ? AND status = 'applied' ORDER BY id DESC LIMIT 1
            """, arguments: [conversationID])
    }

    /// Toglie soltanto ciò che l'ultima importazione ha aggiunto.
    public func undoLastImport(conversationID: Int64) throws {
        try store.db.write { db in
            guard let batchID = try Self.lastApplied(db, conversationID: conversationID) else {
                throw ImportError.nothingToUndo
            }
            let created = try Bool.fetchOne(db, sql: "SELECT created_conversation FROM import_batch WHERE id = ?",
                                            arguments: [batchID]) ?? false
            if created {
                try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [conversationID])
                return
            }
            try db.execute(sql: "DELETE FROM attachment WHERE batch_id = ?", arguments: [batchID])
            try db.execute(sql: "DELETE FROM message WHERE batch_id = ?", arguments: [batchID])
            try db.execute(sql: "DELETE FROM participant_alias WHERE created_by_batch = ?", arguments: [batchID])
            try db.execute(sql: "DELETE FROM participant WHERE created_by_batch = ?", arguments: [batchID])
            try db.execute(sql: "UPDATE import_batch SET status = 'undone' WHERE id = ?", arguments: [batchID])
        }
        try store.media.removeOrphans(referenced: try store.referencedHashes())
    }
}
