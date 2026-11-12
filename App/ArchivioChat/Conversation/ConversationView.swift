import SwiftUI
import ArchivioCore

struct ViewerRequest: Identifiable {
    let id = UUID()
    let items: [MessageRow]
    let index: Int
}

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let route: ChatRoute
    @State private var vm: ConversationViewModel?

    var body: some View {
        Group {
            if let vm {
                ConversationContent(vm: vm, initialAnchor: route.messageID)
            } else {
                Theme.chatBackground.ignoresSafeArea()
            }
        }
        .onAppear {
            guard vm == nil, let store = model.store else { return }
            let created = ConversationViewModel(conversationID: route.conversationID, store: store)
            created.load(around: route.messageID)
            vm = created
        }
        .toolbar(.hidden, for: .tabBar)
    }
}

private struct ConversationContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var vm: ConversationViewModel
    let initialAnchor: Int64?

    @State private var topID: String?
    @State private var expandedID: Int64?
    @State private var viewer: ViewerRequest?
    @State private var infoRow: MessageRow?
    @State private var showInfo = false
    @State private var showSearch = false
    @State private var atBottom = true
    @State private var pendingJump: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if vm.reachedStart, !vm.items.isEmpty {
                        Text("Inizio della conversazione")
                            .font(.caption).foregroundStyle(Theme.secondaryText).padding(.vertical, 12)
                    }
                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                        row(item)
                            .id(item.id)
                            .onAppear { appeared(index) }
                            .onDisappear { if index == vm.items.count - 1 { atBottom = false } }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollPosition(id: $topID, anchor: .top)
            .defaultScrollAnchor(.bottom)
            .background(Theme.chatBackground)
            .overlay(alignment: .bottomTrailing) {
                if !atBottom || !vm.reachedEnd {
                    Button {
                        vm.load(around: nil)
                        DispatchQueue.main.async {
                            if let last = vm.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline).frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    }
                    .padding(14)
                    .accessibilityLabel("Vai agli ultimi messaggi")
                    .transition(.opacity)
                }
            }
            .overlay {
                if vm.items.isEmpty {
                    ContentUnavailableView("Nessun messaggio", systemImage: "bubble.left")
                }
            }
            .onAppear {
                if let initialAnchor { scroll(proxy, to: initialAnchor) }
            }
            .onChange(of: pendingJump) { _, target in
                guard let target else { return }
                pendingJump = nil
                if !vm.contains(target) { vm.load(around: target) } else { vm.highlight(target) }
                scroll(proxy, to: target)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { showInfo = true } label: {
                    HStack(spacing: 8) {
                        AvatarView(title: vm.info?.title ?? "", url: model.avatarURL(vm.info?.avatarHash), size: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(vm.info?.title ?? "").font(.headline).foregroundStyle(.primary).lineLimit(1)
                            Text("Tocca per le info").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityLabel("Info su \(vm.info?.title ?? "conversazione")")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Cerca nella chat")
            }
        }
        .navigationDestination(isPresented: $showInfo) {
            ConversationInfoView(conversationID: vm.conversationID,
                                 onChanged: { vm.load(around: nil) },
                                 onDeleted: { dismiss() },
                                 onJump: { id in showInfo = false; pendingJump = id })
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet(conversationID: vm.conversationID, participants: vm.info?.participants ?? []) { hit in
                showSearch = false
                pendingJump = hit.message.id
            }
        }
        .sheet(item: $infoRow) { row in
            MessageInfoSheet(row: row).presentationDetents([.medium])
        }
        .fullScreenCover(item: $viewer) { request in
            MediaViewer(items: request.items, startIndex: request.index) { id in
                viewer = nil
                pendingJump = id
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to messageID: Int64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(ChatItem.id(forMessage: messageID), anchor: .center)
        }
    }

    private func appeared(_ index: Int) {
        if index < 12 { vm.loadEarlier() }
        if index >= vm.items.count - 12 { vm.loadLater() }
        if index == vm.items.count - 1 { atBottom = true }
    }

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item {
        case .day(let day):
            Text(Dates.dayLabel(day))
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8))
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
        case .message(let message, let startsGroup):
            MessageRowView(row: message, startsGroup: startsGroup, showSender: vm.isGroup,
                           highlighted: vm.highlightedID == message.id,
                           expanded: expandedID == message.id,
                           onTap: { withAnimation(.easeOut(duration: 0.15)) { expandedID = expandedID == message.id ? nil : message.id } },
                           onOpen: { viewer = ViewerRequest(items: [message], index: 0) },
                           onStar: { vm.toggleStar(message); model.reload() },
                           onInfo: { infoRow = message })
                .padding(.top, startsGroup ? 6 : 2)
        }
    }
}

/// Dettagli di un messaggio: data completa, mittente, tipo.
struct MessageInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    let row: MessageRow

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Data e ora", value: Dates.full(row.ts))
                if let sender = row.senderName { LabeledContent("Mittente", value: sender) }
                LabeledContent("Tipo", value: kindLabel)
                if let a = row.attachment {
                    LabeledContent("File", value: a.fileName)
                    LabeledContent("Dimensione", value: ByteCountFormatter.string(fromByteCount: a.byteSize, countStyle: .file))
                }
                if row.edited { Label("Modificato dopo l'invio", systemImage: "pencil") }
                if row.starred { Label("Tra i preferiti", systemImage: "star.fill") }
                if row.possibleDuplicate {
                    Label("Possibile doppione: assomiglia a un messaggio già presente nello stesso istante, quindi è stato conservato.",
                          systemImage: "doc.on.doc")
                }
            }
            .navigationTitle("Info messaggio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
    }

    private var kindLabel: String {
        switch row.kind {
        case .text: return "Testo"
        case .call: return "Chiamata"
        case .deleted: return "Messaggio eliminato"
        case .system: return "Messaggio di servizio"
        default: return MessagePreview.label(row.kind) + (row.mediaMissing ? " (non disponibile)" : "")
        }
    }
}
