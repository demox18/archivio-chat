import Foundation
import GRDB

/// Le letture (e le poche scritture dell'utente) che servono all'interfaccia.
extension ArchiveStore {
    private static let messageSelect = """
        SELECT m.id, m.conversation_id, m.ts, m.batch_id, m.seq, m.kind, m.text, m.participant_id,
               m.edited, m.possible_duplicate,
               p.display_name AS sender, COALESCE(p.is_me, 0) AS is_me,
               EXISTS(SELECT 1 FROM star s WHERE s.message_id = m.id) AS starred,
               a.file_name, a.sha256, a.byte_size, a.playable_hash
        FROM message m
        LEFT JOIN participant p ON p.id = m.participant_id
        LEFT JOIN attachment a ON a.id = (SELECT MIN(id) FROM attachment WHERE message_id = m.id)
        """

    private static func messageRow(_ row: Row) -> MessageRow {
        var attachment: AttachmentInfo?
        if let hash: String = row["sha256"] {
            attachment = AttachmentInfo(fileName: row["file_name"], sha256: hash,
                                        byteSize: row["byte_size"], playableHash: row["playable_hash"])
        }
        return MessageRow(id: row["id"], conversationID: row["conversation_id"], ts: row["ts"],
                          batchID: row["batch_id"], seq: row["seq"],
                          kind: MessageKind(rawValue: row["kind"]) ?? .text, text: row["text"],
                          participantID: row["participant_id"], senderName: row["sender"],
                          isMe: row["is_me"], edited: row["edited"], possibleDuplicate: row["possible_duplicate"],
                          starred: row["starred"], attachment: attachment)
    }

    // MARK: - Elenco delle chat

    public func chatList() throws -> [ChatSummary] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.id, c.title, c.avatar_hash,
                       (SELECT COUNT(*) FROM message WHERE conversation_id = c.id) AS n,
                       (SELECT COUNT(*) FROM star s JOIN message x ON x.id = s.message_id WHERE x.conversation_id = c.id) AS stars,
                       (SELECT id FROM message WHERE conversation_id = c.id
                        ORDER BY ts DESC, batch_id DESC, seq DESC LIMIT 1) AS last_id
                FROM conversation c
                """)
            var out: [ChatSummary] = []
            for row in rows {
                var summary = ChatSummary(id: row["id"], title: row["title"], avatarHash: row["avatar_hash"],
                                          lastText: "", lastKind: nil, lastIsMe: false, lastTS: nil,
                                          messageCount: row["n"], starredCount: row["stars"])
                if let lastID: Int64 = row["last_id"],
                   let last = try Row.fetchOne(db, sql: Self.messageSelect + " WHERE m.id = ?", arguments: [lastID]).map(Self.messageRow) {
                    summary.lastText = last.text
                    summary.lastKind = last.kind
                    summary.lastIsMe = last.isMe
                    summary.lastTS = last.ts
                }
                out.append(summary)
            }
            return out.sorted { ($0.lastTS ?? 0, $0.id) > ($1.lastTS ?? 0, $1.id) }
        }
    }

    // MARK: - Messaggi a pagine

    public func message(id: Int64) throws -> MessageRow? {
        try db.read { try Row.fetchOne($0, sql: Self.messageSelect + " WHERE m.id = ?", arguments: [id]).map(Self.messageRow) }
    }

    /// Una finestra di messaggi: gli ultimi, oppure quelli attorno a un messaggio.
    public func messages(conversationID: Int64, around anchorID: Int64?, limit: Int) throws -> [MessageRow] {
        try db.read { db in
            guard let anchorID,
                  let anchor = try Row.fetchOne(db, sql: Self.messageSelect + " WHERE m.id = ? AND m.conversation_id = ?",
                                                arguments: [anchorID, conversationID]).map(Self.messageRow) else {
                return try Self.page(db, conversationID: conversationID, limit: limit, older: true, from: nil).reversed()
            }
            let before = try Self.page(db, conversationID: conversationID, limit: limit / 2, older: true, from: anchor)
            let after = try Self.page(db, conversationID: conversationID, limit: limit - limit / 2 - 1, older: false, from: anchor)
            return before.reversed() + [anchor] + after
        }
    }

    public func messages(conversationID: Int64, before row: MessageRow, limit: Int) throws -> [MessageRow] {
        try db.read { try Self.page($0, conversationID: conversationID, limit: limit, older: true, from: row).reversed() }
    }

    public func messages(conversationID: Int64, after row: MessageRow, limit: Int) throws -> [MessageRow] {
        try db.read { try Self.page($0, conversationID: conversationID, limit: limit, older: false, from: row) }
    }

    /// L'ordine in conversazione è (istante, importazione, posizione nel file).
    private static func page(_ db: Database, conversationID: Int64, limit: Int, older: Bool, from row: MessageRow?) throws -> [MessageRow] {
        guard limit > 0 else { return [] }
        var sql = messageSelect + " WHERE m.conversation_id = ?"
        var args: [DatabaseValueConvertible] = [conversationID]
        if let row {
            sql += " AND (m.ts, m.batch_id, m.seq) \(older ? "<" : ">") (?, ?, ?)"
            args += [row.ts, row.batchID, row.seq]
        }
        sql += older ? " ORDER BY m.ts DESC, m.batch_id DESC, m.seq DESC" : " ORDER BY m.ts, m.batch_id, m.seq"
        sql += " LIMIT ?"
        args.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(messageRow)
    }

    // MARK: - Ricerca

    public func search(_ filter: SearchFilter, limit: Int) throws -> [SearchHit] {
        let text = (filter.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let words = Self.searchWords(text)
        return try db.read { db in
            if text.isEmpty { return try Self.runSearch(db, filter, match: nil, like: nil, limit: limit) }
            // Senza lettere o cifre (per esempio solo emoji) l'indice non aiuta: confronto diretto.
            if words.isEmpty { return try Self.runSearch(db, filter, match: nil, like: text, limit: limit) }
            // Prima come frase esatta; se non c'è, tutte le parole in qualunque ordine.
            let phrase = "\"" + words.joined(separator: " ") + "\"*"
            let hits = try Self.runSearch(db, filter, match: phrase, like: nil, limit: limit)
            if !hits.isEmpty || words.count == 1 { return hits }
            let allWords = words.map { "\"\($0)\"*" }.joined(separator: " AND ")
            return try Self.runSearch(db, filter, match: allWords, like: nil, limit: limit)
        }
    }

    /// Le parole cercate, ripulite da tutto ciò che per l'indice è sintassi.
    static func searchWords(_ text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    private static func runSearch(_ db: Database, _ f: SearchFilter, match: String?, like: String?, limit: Int) throws -> [SearchHit] {
        var sql = """
            SELECT x.*, c.title AS conversation_title FROM (\(messageSelect)) x
            JOIN conversation c ON c.id = x.conversation_id WHERE 1 = 1
            """
        var args: [DatabaseValueConvertible] = []
        if let match {
            sql += " AND x.id IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)"
            args.append(match)
        }
        if let like {
            let escaped = like.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
            sql += " AND x.text LIKE ? ESCAPE '\\'"
            args.append("%\(escaped)%")
        }
        if let id = f.conversationID { sql += " AND x.conversation_id = ?"; args.append(id) }
        if let id = f.participantID { sql += " AND x.participant_id = ?"; args.append(id) }
        if let day = f.day { sql += " AND x.ts >= ? AND x.ts < ?"; args += [day, day + 86_400] }
        if f.starredOnly { sql += " AND x.starred = 1" }
        sql += " ORDER BY x.ts DESC, x.batch_id DESC, x.seq DESC LIMIT ?"
        args.append(limit)
        return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map {
            SearchHit(message: messageRow($0), conversationTitle: $0["conversation_title"])
        }
    }

    // MARK: - Stelle

    /// La stella vive in una tabella a parte: il messaggio non viene mai toccato.
    public func setStar(messageID: Int64, _ on: Bool) throws {
        try db.write { db in
            if on {
                try db.execute(sql: "INSERT OR IGNORE INTO star(message_id, created_at) VALUES (?, ?)",
                               arguments: [messageID, Int64(Date().timeIntervalSince1970)])
            } else {
                try db.execute(sql: "DELETE FROM star WHERE message_id = ?", arguments: [messageID])
            }
        }
    }

    public func starred(conversationID: Int64? = nil) throws -> [SearchHit] {
        try search(SearchFilter(starredOnly: true, conversationID: conversationID), limit: 5000)
    }

    // MARK: - Raccolta "Media, link e documenti"

    public func mediaItems(conversationID: Int64, section: MediaSection, limit: Int, offset: Int) throws -> [MessageRow] {
        let condition: String
        switch section {
        case .media: condition = "x.kind IN ('photo', 'video', 'gif') AND x.sha256 IS NOT NULL"
        case .stickers: condition = "x.kind = 'sticker' AND x.sha256 IS NOT NULL"
        case .audio: condition = "x.kind = 'audio' AND x.sha256 IS NOT NULL"
        case .documents: condition = "x.kind = 'document' AND x.sha256 IS NOT NULL"
        case .links: condition = "x.kind = 'text' AND (x.text LIKE '%http://%' OR x.text LIKE '%https://%')"
        }
        return try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT x.* FROM (\(Self.messageSelect) WHERE m.conversation_id = ?) x
                WHERE \(condition)
                ORDER BY x.ts DESC, x.batch_id DESC, x.seq DESC LIMIT ? OFFSET ?
                """, arguments: [conversationID, limit, offset]).map(Self.messageRow)
        }
    }

    // MARK: - Scheda della conversazione

    public func conversationInfo(id: Int64) throws -> ConversationInfo {
        try db.read { db in
            guard let c = try Row.fetchOne(db, sql: """
                SELECT c.title, c.avatar_hash,
                       (SELECT COUNT(*) FROM message WHERE conversation_id = c.id) AS n,
                       (SELECT MIN(ts) FROM message WHERE conversation_id = c.id) AS first_ts,
                       (SELECT MAX(ts) FROM message WHERE conversation_id = c.id) AS last_ts,
                       (SELECT COUNT(*) FROM attachment a JOIN message x ON x.id = a.message_id WHERE x.conversation_id = c.id) AS files,
                       (SELECT COUNT(*) FROM star s JOIN message x ON x.id = s.message_id WHERE x.conversation_id = c.id) AS stars
                FROM conversation c WHERE c.id = ?
                """, arguments: [id]) else { throw ImportError.conversationNotFound }

            var participants: [ParticipantInfo] = []
            for p in try Row.fetchAll(db, sql: """
                SELECT p.id, p.display_name, p.is_me, (SELECT COUNT(*) FROM message WHERE participant_id = p.id) AS n
                FROM participant p WHERE p.conversation_id = ? ORDER BY p.is_me DESC, p.id
                """, arguments: [id]) {
                let aliases = try String.fetchAll(db, sql: "SELECT name FROM participant_alias WHERE participant_id = ? ORDER BY id",
                                                  arguments: [p["id"] as Int64])
                participants.append(ParticipantInfo(id: p["id"], displayName: p["display_name"], isMe: p["is_me"],
                                                    aliases: aliases, messageCount: p["n"]))
            }
            let imports = try Row.fetchAll(db, sql: """
                SELECT id, file_name, created_at, status, summary_json FROM import_batch WHERE conversation_id = ? ORDER BY id DESC
                """, arguments: [id]).map { row -> ImportInfo in
                let json: String = row["summary_json"]
                return ImportInfo(id: row["id"], fileName: row["file_name"], createdAt: row["created_at"],
                                  applied: (row["status"] as String) == "applied",
                                  summary: try? JSONDecoder().decode(ImportSummary.self, from: Data(json.utf8)))
            }
            return ConversationInfo(id: id, title: c["title"], avatarHash: c["avatar_hash"], messageCount: c["n"],
                                    firstTS: c["first_ts"], lastTS: c["last_ts"], attachmentCount: c["files"],
                                    starredCount: c["stars"], participants: participants, imports: imports)
        }
    }

    public func stats() throws -> ArchiveStats {
        try db.read { db in
            ArchiveStats(conversations: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation")!,
                         messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message")!,
                         attachments: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attachment")!)
        }
    }

    // MARK: - Personalizzazioni dell'utente

    public func rename(conversationID: Int64, to title: String) throws {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try db.write { try $0.execute(sql: "UPDATE conversation SET title = ? WHERE id = ?", arguments: [clean, conversationID]) }
    }

    /// Indica quale partecipante è l'utente (o nessuno, con `nil`).
    public func setMe(conversationID: Int64, participantID: Int64?) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE participant SET is_me = 0 WHERE conversation_id = ?", arguments: [conversationID])
            if let participantID {
                try db.execute(sql: "UPDATE participant SET is_me = 1 WHERE id = ? AND conversation_id = ?",
                               arguments: [participantID, conversationID])
            }
        }
    }

    /// Imposta l'immagine della conversazione copiando il file indicato nell'archivio.
    public func setAvatar(conversationID: Int64, imageFile: URL?) throws {
        var hash: String?
        if let imageFile { hash = try media.ingest(copying: imageFile, ext: "jpg").hash }
        try db.write { try $0.execute(sql: "UPDATE conversation SET avatar_hash = ? WHERE id = ?", arguments: [hash, conversationID]) }
        try media.removeOrphans(referenced: try referencedHashes())
    }

    /// Elimina un'intera conversazione. Solo su richiesta esplicita dell'utente.
    public func deleteConversation(id: Int64) throws {
        try db.write { try $0.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: [id]) }
        try media.removeOrphans(referenced: try referencedHashes())
    }
}
