import Foundation

public enum ImportError: Error, Equatable, LocalizedError {
    case noMessages
    case noChatFile
    case archiveChanged
    case notEnoughSpace(needed: Int64)
    case conversationNotFound
    case invalidParticipant
    case nothingToUndo
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .noMessages: return "Il file non contiene messaggi riconoscibili."
        case .noChatFile: return "Lo ZIP non contiene il file della chat (_chat.txt)."
        case .archiveChanged: return "L'archivio è cambiato dopo l'analisi. Ripeti l'importazione."
        case .notEnoughSpace(let needed):
            let mb = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            return "Spazio insufficiente sull'iPhone: servono circa \(mb)."
        case .conversationNotFound: return "La conversazione non esiste più."
        case .invalidParticipant: return "Abbinamento dei nomi non valido."
        case .nothingToUndo: return "Non c'è nessuna importazione da annullare."
        case .unreadable(let why): return why
        }
    }
}

/// A chi corrisponde un nome di mittente del file.
public enum ParticipantChoice: Equatable, Sendable {
    case existing(Int64)
    case new(isMe: Bool)
}

public enum ImportTarget: Sendable {
    /// `me` è il nome, come scritto nel file, con cui compare l'utente.
    case newConversation(title: String, me: String?)
    /// I nomi non presenti in `senders` vengono risolti tramite gli alias già noti;
    /// quelli ancora sconosciuti diventano nuovi partecipanti.
    case existing(conversationID: Int64, senders: [String: ParticipantChoice])
}

/// I numeri dell'anteprima mostrata prima di confermare.
public struct ImportSummary: Codable, Equatable, Sendable {
    public var totalInFile = 0
    public var alreadyPresent = 0
    public var newMessages = 0
    public var possibleDuplicates = 0
    /// File presenti nella sorgente e citati dalla chat.
    public var photos = 0, videos = 0, stickers = 0, audios = 0, documents = 0
    /// Allegati che verranno collegati a messaggi già in archivio.
    public var attachmentsToLink = 0
    /// Allegati citati dalla chat ma assenti sia nel file sia nell'archivio.
    public var missingAttachments = 0
    public var unrecognizedLines = 0
    /// Vero se le date del file toccano quelle già in archivio.
    public var overlaps = false
    /// Mittenti del file che diventeranno nuovi partecipanti.
    public var newParticipants: [String] = []
    public var firstTS: Int64 = 0
    public var lastTS: Int64 = 0

    public init() {}
}

public struct TargetSuggestion: Sendable {
    public var senders: [String]
    /// Conversazione che conosce già uno dei mittenti (escluso l'utente stesso).
    public var matchedConversationID: Int64?
    public var suggestedTitle: String
    /// Mittente che in altre chat è già segnato come "io".
    public var likelyMe: String?
    public var messageCount: Int
}

/// Il risultato dell'analisi: cosa succederebbe confermando. Non scrive nulla.
public struct ImportPlan: Sendable {
    public let summary: ImportSummary
    public let fileName: String

    struct NewParticipant: Sendable { let name: String; let isMe: Bool }
    struct Snapshot: Sendable, Equatable { let messages: Int; let maxMessageID: Int64; let attachments: Int }

    let source: any ImportSource
    let fileHash: String
    let target: ImportTarget
    let messages: [ParsedMessage]
    let decisions: [Merger.Decision]
    /// Per ogni messaggio: id del partecipante esistente, oppure -(indice+1)
    /// in `newParticipants`, oppure 0 se la riga non ha mittente.
    let participantKeys: [Int64]
    let newParticipants: [NewParticipant]
    let aliasAdds: [(name: String, participantID: Int64)]
    let snapshot: Snapshot?
}
