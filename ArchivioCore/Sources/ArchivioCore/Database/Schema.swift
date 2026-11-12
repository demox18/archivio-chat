import Foundation
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE conversation(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                avatar_hash TEXT,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE import_batch(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                file_name TEXT NOT NULL,
                file_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                status TEXT NOT NULL,
                created_conversation INTEGER NOT NULL DEFAULT 0,
                summary_json TEXT NOT NULL
            );

            CREATE TABLE participant(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                is_me INTEGER NOT NULL DEFAULT 0,
                created_by_batch INTEGER
            );

            CREATE TABLE participant_alias(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                participant_id INTEGER NOT NULL REFERENCES participant(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                created_by_batch INTEGER,
                UNIQUE(conversation_id, name)
            );

            -- participant_id senza CASCADE di proposito: togliere un partecipante
            -- che ha ancora messaggi deve fallire, non cancellare i messaggi.
            CREATE TABLE message(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
                participant_id INTEGER REFERENCES participant(id),
                ts INTEGER NOT NULL,
                kind TEXT NOT NULL,
                text TEXT NOT NULL,
                attachment_name TEXT,
                edited INTEGER NOT NULL DEFAULT 0,
                possible_duplicate INTEGER NOT NULL DEFAULT 0,
                batch_id INTEGER NOT NULL REFERENCES import_batch(id) ON DELETE CASCADE,
                source_line INTEGER NOT NULL,
                seq INTEGER NOT NULL
            );
            CREATE INDEX message_order ON message(conversation_id, ts, batch_id, seq);
            CREATE INDEX message_batch ON message(batch_id);
            CREATE INDEX message_participant ON message(participant_id);

            CREATE TABLE attachment(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                message_id INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                file_name TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                byte_size INTEGER NOT NULL,
                kind TEXT NOT NULL,
                playable_hash TEXT,
                batch_id INTEGER NOT NULL REFERENCES import_batch(id) ON DELETE CASCADE
            );
            CREATE INDEX attachment_message ON attachment(message_id);
            CREATE INDEX attachment_hash ON attachment(sha256);
            CREATE INDEX attachment_batch ON attachment(batch_id);

            CREATE TABLE star(
                message_id INTEGER PRIMARY KEY REFERENCES message(id) ON DELETE CASCADE,
                created_at INTEGER NOT NULL
            );

            CREATE VIRTUAL TABLE message_fts USING fts5(
                text, content='message', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                INSERT INTO message_fts(rowid, text) VALUES (new.id, new.text);
            END;
            CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                INSERT INTO message_fts(message_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END;
            """)
        }
        return m
    }
}
