import SwiftUI
import ArchivioCore

/// La scheda "Preferiti": tutti i messaggi con la stella, di tutte le chat.
struct StarredView: View {
    @State private var path: [ChatRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            StarredList(conversationID: nil) { hit in
                path.append(ChatRoute(conversationID: hit.message.conversationID, messageID: hit.message.id))
            }
            .navigationTitle("Preferiti")
            .navigationDestination(for: ChatRoute.self) { ConversationView(route: $0) }
        }
    }
}

struct StarredList: View {
    @Environment(AppModel.self) private var model
    let conversationID: Int64?
    let onSelect: (SearchHit) -> Void
    @State private var hits: [SearchHit] = []

    private var groups: [(title: String, hits: [SearchHit])] {
        var order: [Int64] = []
        var byChat: [Int64: [SearchHit]] = [:]
        for hit in hits {
            if byChat[hit.message.conversationID] == nil { order.append(hit.message.conversationID) }
            byChat[hit.message.conversationID, default: []].append(hit)
        }
        return order.map { (byChat[$0]![0].conversationTitle, byChat[$0]!) }
    }

    var body: some View {
        Group {
            if hits.isEmpty {
                ContentUnavailableView("Nessun messaggio importante", systemImage: "star",
                                       description: Text("Tieni premuto un messaggio e scegli \"Aggiungi ai preferiti\"."))
            } else {
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(conversationID == nil ? group.title : "") {
                            ForEach(group.hits) { hit in
                                Button { onSelect(hit) } label: {
                                    SearchHitRow(hit: hit, query: "", showsChatTitle: false)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button("Togli stella") {
                                        try? model.store?.setStar(messageID: hit.message.id, false)
                                        model.reload()
                                    }
                                    .tint(.orange)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .task(id: model.revision) {
            hits = (try? model.store?.starred(conversationID: conversationID)) ?? []
        }
    }
}
