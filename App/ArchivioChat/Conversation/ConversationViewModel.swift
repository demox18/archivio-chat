import SwiftUI
import Observation
import ArchivioCore

/// Una riga della conversazione: un separatore di giornata oppure un messaggio.
enum ChatItem: Identifiable, Equatable {
    case day(Int64)
    case message(MessageRow, startsGroup: Bool)

    var id: String {
        switch self {
        case .day(let d): return "d\(d)"
        case .message(let m, _): return ChatItem.id(forMessage: m.id)
        }
    }

    static func id(forMessage id: Int64) -> String { "m\(id)" }
}

/// Tiene in memoria una finestra di messaggi e ne carica altri scorrendo:
/// necessario con conversazioni da decine di migliaia di messaggi.
@MainActor
@Observable
final class ConversationViewModel {
    let conversationID: Int64
    private let store: ArchiveStore
    private let pageSize = 150

    private(set) var rows: [MessageRow] = []
    private(set) var items: [ChatItem] = []
    private(set) var info: ConversationInfo?
    private(set) var reachedStart = false
    private(set) var reachedEnd = true
    private(set) var highlightedID: Int64?
    private var loading = false

    /// Vero quando i partecipanti sono più di due: si mostra il nome del mittente.
    var isGroup: Bool { (info?.participants.count ?? 0) > 2 }

    init(conversationID: Int64, store: ArchiveStore) {
        self.conversationID = conversationID
        self.store = store
    }

    func reloadInfo() {
        info = try? store.conversationInfo(id: conversationID)
    }

    /// Carica gli ultimi messaggi, oppure quelli attorno a un messaggio.
    func load(around anchor: Int64?) {
        reloadInfo()
        let limit = anchor == nil ? pageSize : pageSize * 2
        rows = (try? store.messages(conversationID: conversationID, around: anchor, limit: limit)) ?? []
        reachedEnd = anchor == nil
        reachedStart = rows.count < limit && anchor == nil
        rebuild()
        if anchor != nil { highlight(anchor) }
    }

    func loadEarlier() {
        guard !loading, !reachedStart, let first = rows.first else { return }
        loading = true
        defer { loading = false }
        let older = (try? store.messages(conversationID: conversationID, before: first, limit: pageSize)) ?? []
        if older.count < pageSize { reachedStart = true }
        guard !older.isEmpty else { return }
        rows.insert(contentsOf: older, at: 0)
        rebuild()
    }

    func loadLater() {
        guard !loading, !reachedEnd, let last = rows.last else { return }
        loading = true
        defer { loading = false }
        let newer = (try? store.messages(conversationID: conversationID, after: last, limit: pageSize)) ?? []
        if newer.count < pageSize { reachedEnd = true }
        guard !newer.isEmpty else { return }
        rows.append(contentsOf: newer)
        rebuild()
    }

    func highlight(_ id: Int64?) {
        highlightedID = id
        guard let id else { return }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if highlightedID == id { withAnimation(.easeOut(duration: 0.4)) { highlightedID = nil } }
        }
    }

    func contains(_ id: Int64) -> Bool { rows.contains { $0.id == id } }

    func toggleStar(_ row: MessageRow) {
        try? store.setStar(messageID: row.id, !row.starred)
        guard let i = rows.firstIndex(where: { $0.id == row.id }) else { return }
        rows[i].starred.toggle()
        rebuild()
    }

    private func rebuild() {
        var out: [ChatItem] = []
        out.reserveCapacity(rows.count + 32)
        var previous: MessageRow?
        for row in rows {
            let newDay = previous?.day != row.day
            if newDay { out.append(.day(row.day)) }
            let bubble = Self.isBubble(row.kind)
            let startsGroup = newDay || previous == nil || !Self.isBubble(previous!.kind)
                || previous!.participantID != row.participantID || !bubble
            out.append(.message(row, startsGroup: startsGroup))
            previous = row
        }
        items = out
    }

    private static func isBubble(_ kind: MessageKind) -> Bool { kind != .system && kind != .call }
}
