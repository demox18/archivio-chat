import Foundation

/// Una riga dell'elenco delle chat.
public struct ChatSummary: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var avatarHash: String?
    public var lastText: String
    public var lastKind: MessageKind?
    public var lastIsMe: Bool
    public var lastTS: Int64?
    public var messageCount: Int
    public var starredCount: Int
}

public struct AttachmentInfo: Equatable, Sendable {
    public var fileName: String
    public var sha256: String
    public var byteSize: Int64
    /// Impronta del file riproducibile (per i vocali convertiti), se esiste.
    public var playableHash: String?

    public var ext: String { (fileName as NSString).pathExtension.lowercased() }
}

/// Un messaggio pronto per essere mostrato.
public struct MessageRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var conversationID: Int64
    public var ts: Int64
    public var batchID: Int64
    public var seq: Int64
    public var kind: MessageKind
    public var text: String
    public var participantID: Int64?
    public var senderName: String?
    public var isMe: Bool
    public var edited: Bool
    public var possibleDuplicate: Bool
    public var starred: Bool
    public var attachment: AttachmentInfo?

    /// Un media citato nella chat ma il cui file non è stato importato.
    public var mediaMissing: Bool { kind.isMedia && attachment == nil }
    /// Inizio della giornata (stessi "secondi locali" di `ts`).
    public var day: Int64 { ts - ((ts % 86_400) + 86_400) % 86_400 }
}

public struct SearchHit: Identifiable, Equatable, Sendable {
    public var message: MessageRow
    public var conversationTitle: String
    public var id: Int64 { message.id }
}

public struct SearchFilter: Sendable, Equatable {
    public var text: String?
    public var participantID: Int64?
    /// Inizio della giornata cercata.
    public var day: Int64?
    public var starredOnly: Bool
    public var conversationID: Int64?

    public init(text: String? = nil, participantID: Int64? = nil, day: Int64? = nil,
                starredOnly: Bool = false, conversationID: Int64? = nil) {
        self.text = text; self.participantID = participantID; self.day = day
        self.starredOnly = starredOnly; self.conversationID = conversationID
    }

    public var isEmpty: Bool {
        (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty && participantID == nil && day == nil && !starredOnly
    }
}

public enum MediaSection: String, CaseIterable, Sendable {
    case media, stickers, audio, documents, links
}

public struct ParticipantInfo: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var displayName: String
    public var isMe: Bool
    public var aliases: [String]
    public var messageCount: Int
}

public struct ImportInfo: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var fileName: String
    public var createdAt: Int64
    public var applied: Bool
    public var summary: ImportSummary?
}

public struct ConversationInfo: Equatable, Sendable {
    public var id: Int64
    public var title: String
    public var avatarHash: String?
    public var messageCount: Int
    public var firstTS: Int64?
    public var lastTS: Int64?
    public var attachmentCount: Int
    public var starredCount: Int
    public var participants: [ParticipantInfo]
    public var imports: [ImportInfo]
}

public struct ArchiveStats: Equatable, Sendable {
    public var conversations: Int
    public var messages: Int
    public var attachments: Int
}
