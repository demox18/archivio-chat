import Foundation

/// Le frasi fisse con cui WhatsApp per iPhone scrive allegati, media omessi e
/// righe di servizio. Italiano e inglese; per un'altra lingua basta aggiungere voci.
enum Dialect {
    /// Parola che precede il nome del file: `<allegato: nome.jpg>`.
    static let attachmentTags = ["allegato", "attached"]

    /// Testo intero del messaggio (minuscolo) → tipo di media omesso.
    static let omitted: [String: MessageKind] = [
        "immagine omessa": .photo, "image omitted": .photo,
        "video omesso": .video, "video omitted": .video,
        "audio omesso": .audio, "audio omitted": .audio,
        "sticker non incluso": .sticker, "sticker omesso": .sticker, "sticker omitted": .sticker,
        "gif esclusa": .gif, "gif omessa": .gif, "gif omitted": .gif,
        "documento omesso": .document, "document omitted": .document,
    ]

    static let deleted: Set<String> = [
        "hai eliminato questo messaggio.", "questo messaggio è stato eliminato.",
        "you deleted this message.", "this message was deleted.",
    ]

    /// Inizio (minuscolo) delle righe di chiamata.
    static let callPrefixes = [
        "chiamata", "videochiamata", "voice call", "video call",
        "missed voice call", "missed video call", "missed call",
    ]

    static let editedMarkers = [
        "<Questo messaggio è stato modificato>", "<This message was edited>",
    ]

    static func kind(forAttachmentNamed name: String) -> MessageKind {
        let upper = name.uppercased()
        if upper.contains("-PHOTO-") { return .photo }
        if upper.contains("-VIDEO-") { return .video }
        if upper.contains("-GIF-") { return .gif }
        if upper.contains("-STICKER-") { return .sticker }
        if upper.contains("-AUDIO-") || upper.contains("-PTT-") { return .audio }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic": return .photo
        case "mp4", "mov", "m4v": return .video
        case "webp": return .sticker
        case "opus", "m4a", "mp3", "aac", "ogg", "wav": return .audio
        default: return .document
        }
    }
}
