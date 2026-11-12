import SwiftUI
import PhotosUI
import ArchivioCore

/// La scheda della conversazione: nome, immagine, numeri, raccolta dei media,
/// partecipanti e storico delle importazioni.
struct ConversationInfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationID: Int64
    let onChanged: () -> Void
    let onDeleted: () -> Void
    let onJump: (Int64) -> Void

    @State private var info: ConversationInfo?
    @State private var photoItem: PhotosPickerItem?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var undoCandidate: (batchID: Int64, starsLost: Int)?
    @State private var confirmUndo = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAgain = false
    @State private var errorMessage: String?
    @State private var showGallery: Bool = {
        #if DEBUG
        return DemoLaunch.open == "gallery"
        #else
        return false
        #endif
    }()

    var body: some View {
        List {
            if let info {
                header(info)
                Section {
                    LabeledContent("Messaggi", value: info.messageCount.formatted())
                    if let first = info.firstTS { LabeledContent("Primo messaggio", value: Dates.long(first)) }
                    if let last = info.lastTS { LabeledContent("Ultimo messaggio", value: Dates.long(last)) }
                }
                Section {
                    NavigationLink {
                        MediaGalleryView(conversationID: conversationID, onJump: onJump)
                    } label: {
                        LabeledContent { Text(info.attachmentCount.formatted()) } label: {
                            Label("Media, link e documenti", systemImage: "photo.on.rectangle")
                        }
                    }
                    NavigationLink {
                        StarredList(conversationID: conversationID) { onJump($0.message.id) }
                            .navigationTitle("Messaggi importanti")
                    } label: {
                        LabeledContent { Text(info.starredCount.formatted()) } label: {
                            Label("Messaggi importanti", systemImage: "star")
                        }
                    }
                }
                participants(info)
                imports(info)
                Section {
                    Button("Elimina conversazione", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Elimina dall'archivio tutti i messaggi e gli allegati di questa chat. I file originali che hai importato non vengono toccati.")
                }
            }
        }
        .navigationTitle("Info chat")
        .navigationDestination(isPresented: $showGallery) {
            MediaGalleryView(conversationID: conversationID, onJump: onJump)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await setAvatar(item) }
        }
        .alert("Nome della chat", isPresented: $renaming) {
            TextField("Nome", text: $newTitle)
            Button("Salva") {
                try? model.store?.rename(conversationID: conversationID, to: newTitle)
                changed()
            }
            Button("Annulla", role: .cancel) {}
        }
        .confirmationDialog("Annullare l'ultima importazione?", isPresented: $confirmUndo, titleVisibility: .visible) {
            Button("Annulla l'importazione", role: .destructive, action: undo)
            Button("Non ora", role: .cancel) {}
        } message: {
            Text(undoMessage)
        }
        .confirmationDialog("Eliminare questa conversazione?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { confirmDeleteAgain = true }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Verranno rimossi \(info?.messageCount.formatted() ?? "tutti i") messaggi e i relativi allegati.")
        }
        .alert("Conferma definitiva", isPresented: $confirmDeleteAgain) {
            Button("Elimina per sempre", role: .destructive, action: delete)
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("L'operazione non si può annullare. Potrai ricreare la chat solo importando di nuovo i file.")
        }
        .alert("Operazione non riuscita", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func header(_ info: ConversationInfo) -> some View {
        Section {
            VStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    AvatarView(title: info.title, url: model.avatarURL(info.avatarHash), size: 110)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "camera.fill").font(.footnote).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(Theme.accent, in: Circle())
                        }
                }
                .accessibilityLabel("Cambia immagine della chat")
                Button {
                    newTitle = info.title
                    renaming = true
                } label: {
                    HStack(spacing: 6) {
                        Text(info.title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                        Image(systemName: "pencil").font(.footnote)
                    }
                }
                if info.avatarHash != nil {
                    Button("Rimuovi immagine") {
                        try? model.store?.setAvatar(conversationID: conversationID, imageFile: nil)
                        changed()
                    }
                    .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func participants(_ info: ConversationInfo) -> some View {
        Section {
            ForEach(info.participants) { p in
                HStack {
                    AvatarView(title: p.displayName, url: nil, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.isMe ? "\(p.displayName) (tu)" : p.displayName)
                        let others = p.aliases.filter { $0 != p.displayName }
                        if !others.isEmpty {
                            Text("Anche: " + others.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(p.messageCount.formatted()) messaggi").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button(p.isMe ? "Non sono io" : "Sono io") {
                            try? model.store?.setMe(conversationID: conversationID, participantID: p.isMe ? nil : p.id)
                            changed()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Opzioni per \(p.displayName)")
                }
            }
        } header: {
            Text("Partecipanti")
        } footer: {
            Text("I messaggi di chi è segnato come \"tu\" compaiono a destra.")
        }
    }

    private func imports(_ info: ConversationInfo) -> some View {
        Section {
            ForEach(info.imports) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName).font(.subheadline).lineLimit(2)
                    Text(importDetail(item)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if info.imports.contains(where: \.applied) {
                Button("Annulla ultima importazione", role: .destructive) {
                    undoCandidate = try? model.importer?.canUndo(conversationID: conversationID)
                    confirmUndo = undoCandidate != nil
                }
            }
        } header: {
            Text("Importazioni")
        } footer: {
            Text("L'annullamento toglie solo ciò che l'ultima importazione ha aggiunto. Le importazioni precedenti restano intatte.")
        }
    }

    private func importDetail(_ item: ImportInfo) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(item.createdAt)).formatted(date: .abbreviated, time: .shortened)
        guard item.applied else { return "\(date) · annullata" }
        guard let s = item.summary else { return date }
        var parts = ["\(s.newMessages.formatted()) messaggi aggiunti"]
        if s.attachmentsToLink > 0 { parts.append("\(s.attachmentsToLink.formatted()) allegati collegati") }
        return "\(date) · " + parts.joined(separator: ", ")
    }

    private var undoMessage: String {
        guard let info, let c = undoCandidate, let item = info.imports.first(where: { $0.id == c.batchID }) else { return "" }
        var text = "Verrà rimosso ciò che ha aggiunto \"\(item.fileName)\""
        if let s = item.summary { text += ": \(s.newMessages.formatted()) messaggi" }
        text += "."
        if c.starsLost > 0 { text += " Perderai \(c.starsLost) stelle messe su quei messaggi." }
        if info.imports.filter(\.applied).count == 1 { text += " È l'unica importazione: la chat verrà rimossa." }
        return text
    }

    private func reload() {
        info = try? model.store?.conversationInfo(id: conversationID)
    }

    private func changed() {
        model.reload()
        reload()
        onChanged()
    }

    private func undo() {
        do {
            try model.importer?.undoLastImport(conversationID: conversationID)
            model.reload()
            if (try? model.store?.conversationInfo(id: conversationID)) == nil {
                dismiss()
                onDeleted()
            } else {
                reload()
                onChanged()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try model.store?.deleteConversation(id: conversationID)
            model.reload()
            dismiss()
            onDeleted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setAvatar(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
        let side: CGFloat = 512
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        guard (try? square.jpegData(compressionQuality: 0.85)?.write(to: tmp)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        try? model.store?.setAvatar(conversationID: conversationID, imageFile: tmp)
        photoItem = nil
        changed()
    }
}
