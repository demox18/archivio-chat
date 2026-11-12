import Foundation

public enum MessageKind: String, Codable, Sendable, CaseIterable {
    case text, photo, video, gif, sticker, audio, document, call, deleted, system

    public var isMedia: Bool {
        switch self {
        case .photo, .video, .gif, .sticker, .audio, .document: return true
        case .text, .call, .deleted, .system: return false
        }
    }
}

/// Un messaggio così come è scritto nel file di esportazione.
public struct ParsedMessage: Equatable, Sendable {
    /// Secondi dal 1970 ottenuti leggendo data e ora del file come se fossero UTC.
    public var ts: Int64
    /// Nome del mittente come scritto nel file; `nil` solo per righe senza mittente.
    public var sender: String?
    public var kind: MessageKind
    /// Testo senza caratteri invisibili di direzione e senza marcatore di modifica.
    public var text: String
    /// Nome del file allegato; `nil` per il testo e per i media omessi.
    public var attachmentName: String?
    public var edited: Bool
    /// Numero di riga (da 1) nel file d'origine.
    public var line: Int

    public init(ts: Int64, sender: String?, kind: MessageKind, text: String,
                attachmentName: String? = nil, edited: Bool = false, line: Int) {
        self.ts = ts; self.sender = sender; self.kind = kind; self.text = text
        self.attachmentName = attachmentName; self.edited = edited; self.line = line
    }
}

public struct ParseResult: Sendable {
    public var messages: [ParsedMessage]
    /// Righe che precedono la prima intestazione valida.
    public var unrecognizedLines: Int
    /// Nomi dei mittenti in ordine di prima comparsa.
    public var senders: [String]
}
