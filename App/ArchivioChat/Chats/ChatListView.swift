import SwiftUI
import UniformTypeIdentifiers
import ArchivioCore

struct ImportRequest: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ChatListView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ChatRoute] = []
    @State private var searchText = ""
    @State private var showPicker = false
    @State private var importRequest: ImportRequest?

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsList(filter: SearchFilter(text: searchText)) { hit in
                        path.append(ChatRoute(conversationID: hit.message.conversationID, messageID: hit.message.id))
                    }
                } else if model.chats.isEmpty {
                    ContentUnavailableView {
                        Label("Nessuna chat", systemImage: "tray")
                    } description: {
                        Text("Esporta una chat da WhatsApp (con o senza media) e importala qui. I file restano su questo iPhone.")
                    } actions: {
                        Button("Importa una chat") { showPicker = true }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List(model.chats) { chat in
                        NavigationLink(value: ChatRoute(conversationID: chat.id, messageID: nil)) {
                            ChatRow(chat: chat)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chat")
            .searchable(text: $searchText, prompt: "Cerca in tutte le chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showPicker = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Importa chat")
                }
            }
            .navigationDestination(for: ChatRoute.self) { route in
                ConversationView(route: route)
            }
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.zip, .plainText, .text],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                importRequest = ImportRequest(urls: urls)
            }
        }
        .sheet(item: $importRequest) { request in
            ImportFlowView(urls: request.urls)
                .interactiveDismissDisabled()
        }
    }
}

struct ChatRow: View {
    @Environment(AppModel.self) private var model
    let chat: ChatSummary

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(title: chat.title, url: model.avatarURL(chat.avatarHash), size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    if let ts = chat.lastTS {
                        Text(Dates.listLabel(ts)).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                }
                HStack(spacing: 4) {
                    if let icon = MessagePreview.icon(chat.lastKind) {
                        Image(systemName: icon).font(.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    Text(MessagePreview.text(kind: chat.lastKind, text: chat.lastText))
                        .font(.subheadline).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    Spacer(minLength: 8)
                    if chat.starredCount > 0 {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.star)
                            .accessibilityLabel("Contiene messaggi importanti")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Testo breve che riassume un messaggio (elenco chat, risultati di ricerca).
enum MessagePreview {
    static func icon(_ kind: MessageKind?) -> String? {
        switch kind {
        case .photo: return "camera.fill"
        case .video: return "video.fill"
        case .gif: return "play.rectangle.fill"
        case .sticker: return "face.smiling"
        case .audio: return "mic.fill"
        case .document: return "doc.fill"
        case .call: return "phone.fill"
        case .deleted: return "nosign"
        default: return nil
        }
    }

    static func label(_ kind: MessageKind) -> String {
        switch kind {
        case .photo: return "Foto"
        case .video: return "Video"
        case .gif: return "GIF"
        case .sticker: return "Sticker"
        case .audio: return "Messaggio vocale"
        case .document: return "Documento"
        default: return ""
        }
    }

    static func text(kind: MessageKind?, text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let kind, kind.isMedia else { return flat }
        return flat.isEmpty ? label(kind) : flat
    }
}

struct AvatarView: View {
    let title: String
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.color(for: title)
                    Text(initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? "#" : letters
    }
}
