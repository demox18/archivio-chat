import SwiftUI
import ArchivioCore

/// Elenco dei risultati di una ricerca. Toccando un risultato si va al messaggio.
struct SearchResultsList: View {
    @Environment(AppModel.self) private var model
    let filter: SearchFilter
    var showsChatTitle = true
    let onSelect: (SearchHit) -> Void
    @State private var hits: [SearchHit] = []
    @State private var searched = false

    var body: some View {
        Group {
            if filter.isEmpty {
                ContentUnavailableView("Cerca nei messaggi", systemImage: "magnifyingglass",
                                       description: Text("Scrivi una parola o una frase, oppure usa i filtri."))
            } else if hits.isEmpty && searched {
                ContentUnavailableView.search(text: filter.text ?? "")
            } else {
                List(hits) { hit in
                    Button { onSelect(hit) } label: { SearchHitRow(hit: hit, query: filter.text ?? "", showsChatTitle: showsChatTitle) }
                        .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .task(id: TaskKey(filter: filter, revision: model.revision)) {
            // Breve attesa: non si cerca a ogni lettera digitata.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let store = model.store, !filter.isEmpty else { hits = []; return }
            let f = filter
            let result = await Task.detached(priority: .userInitiated) { (try? store.search(f, limit: 300)) ?? [] }.value
            guard !Task.isCancelled else { return }
            hits = result
            searched = true
        }
    }

    private struct TaskKey: Equatable {
        let filter: SearchFilter
        let revision: Int
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let query: String
    var showsChatTitle = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(showsChatTitle ? hit.conversationTitle : (hit.message.senderName ?? ""))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                if hit.message.starred { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.star) }
                Spacer()
                Text(Dates.listLabel(hit.message.ts)).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                if let icon = MessagePreview.icon(hit.message.kind) {
                    Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
                }
                Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Il testo attorno alla parola cercata, con la parola in evidenza.
    private var snippet: AttributedString {
        let m = hit.message
        var text = MessagePreview.text(kind: m.kind, text: m.text)
        if showsChatTitle, let sender = m.senderName { text = "\(sender): \(text)" }
        let words = query.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        // Se la parola è lontana dall'inizio, si parte poco prima.
        if let first = words.first,
           let r = text.range(of: first, options: [.caseInsensitive, .diacriticInsensitive]),
           text.distance(from: text.startIndex, to: r.lowerBound) > 60 {
            let start = text.index(r.lowerBound, offsetBy: -40)
            text = "…" + text[start...]
        }
        var out = AttributedString(text)
        for word in words {
            var searchStart = text.startIndex
            while let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: searchStart..<text.endIndex) {
                if let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) {
                    out[lower..<upper].foregroundColor = .primary
                    out[lower..<upper].font = .subheadline.weight(.semibold)
                }
                searchStart = r.upperBound
            }
        }
        return out
    }
}

/// Ricerca dentro una conversazione, con i filtri per mittente, giorno e preferiti.
struct SearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let conversationID: Int64
    let participants: [ParticipantInfo]
    let onSelect: (SearchHit) -> Void

    @State private var text = ""
    @State private var participantID: Int64?
    @State private var useDay = false
    @State private var day = Date()
    @State private var starredOnly = false

    private var filter: SearchFilter {
        SearchFilter(text: text, participantID: participantID, day: useDay ? Dates.dayStart(of: day) : nil,
                     starredOnly: starredOnly, conversationID: conversationID)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            Button("Tutti") { participantID = nil }
                            ForEach(participants) { p in
                                Button(p.isMe ? "\(p.displayName) (tu)" : p.displayName) { participantID = p.id }
                            }
                        } label: {
                            chip(participants.first { $0.id == participantID }?.displayName ?? "Mittente",
                                 icon: "person", active: participantID != nil)
                        }
                        Button { useDay.toggle() } label: {
                            chip(useDay ? Dates.long(Dates.dayStart(of: day)) : "Giorno", icon: "calendar", active: useDay)
                        }
                        Button { starredOnly.toggle() } label: {
                            chip("Preferiti", icon: starredOnly ? "star.fill" : "star", active: starredOnly)
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                if useDay {
                    DatePicker("Giorno", selection: $day, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .padding(.horizontal).padding(.bottom, 8)
                }
                Divider()
                SearchResultsList(filter: filter, showsChatTitle: false, onSelect: onSelect)
                    .frame(maxHeight: .infinity)
            }
            .navigationTitle("Cerca nella chat")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Parola o frase")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
        }
    }

    private func chip(_ label: String, icon: String, active: Bool) -> some View {
        Label(label, systemImage: icon)
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? Theme.accent.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(active ? Theme.accent : .primary)
    }
}
