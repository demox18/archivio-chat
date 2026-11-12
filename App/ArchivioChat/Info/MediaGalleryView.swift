import SwiftUI
import QuickLook
import ArchivioCore

/// "Media, link e documenti": tutti gli allegati della conversazione,
/// da qualunque file siano stati importati.
struct MediaGalleryView: View {
    @Environment(AppModel.self) private var model
    let conversationID: Int64
    let onJump: (Int64) -> Void

    @State private var section: MediaSection = .media
    @State private var items: [MessageRow] = []
    @State private var exhausted = false
    @State private var viewer: ViewerRequest?
    @State private var previewURL: URL?
    private let pageSize = 240

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sezione", selection: $section) {
                Text("Media").tag(MediaSection.media)
                Text("Sticker").tag(MediaSection.stickers)
                Text("Audio").tag(MediaSection.audio)
                Text("Doc").tag(MediaSection.documents)
                Text("Link").tag(MediaSection.links)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.vertical, 8)

            if items.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: "tray")
                    .frame(maxHeight: .infinity)
            } else {
                switch section {
                case .media, .stickers: grid
                case .audio, .documents, .links: list
                }
            }
        }
        .navigationTitle("Media, link e documenti")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if items.isEmpty { reload() } }
        .onChange(of: section) { _, _ in reload() }
        .fullScreenCover(item: $viewer) { request in
            MediaViewer(items: request.items, startIndex: request.index) { id in
                viewer = nil
                onJump(id)
            }
        }
        .quickLookPreview($previewURL)
    }

    private var emptyTitle: String {
        switch section {
        case .media: return "Nessuna foto o video"
        case .stickers: return "Nessuno sticker"
        case .audio: return "Nessun audio"
        case .documents: return "Nessun documento"
        case .links: return "Nessun link"
        }
    }

    private func reload() {
        items = []
        exhausted = false
        loadMore()
    }

    private func loadMore() {
        guard !exhausted, let store = model.store else { return }
        let more = (try? store.mediaItems(conversationID: conversationID, section: section, limit: pageSize, offset: items.count)) ?? []
        if more.count < pageSize { exhausted = true }
        items.append(contentsOf: more)
    }

    /// Gli elementi raggruppati per mese, dal più recente.
    private var months: [(key: String, rows: [(offset: Int, row: MessageRow)])] {
        var out: [(key: String, rows: [(offset: Int, row: MessageRow)])] = []
        for (i, row) in items.enumerated() {
            let key = Dates.month(row.ts)
            if out.last?.key == key { out[out.count - 1].rows.append((i, row)) } else { out.append((key, [(i, row)])) }
        }
        return out
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: section == .stickers ? 4 : 3)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.key) { month in
                    Section {
                        ForEach(month.rows, id: \.row.id) { entry in
                            cell(entry.row)
                                .onTapGesture { viewer = ViewerRequest(items: items, index: entry.offset) }
                                .onAppear { if entry.offset >= items.count - 30 { loadMore() } }
                        }
                    } header: {
                        Text(month.key).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ row: MessageRow) -> some View {
        if let attachment = row.attachment {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ThumbnailView(attachment: attachment, kind: row.kind, pixels: 320,
                                  contentMode: row.kind == .sticker ? .fit : .fill)
                        .padding(row.kind == .sticker ? 6 : 0)
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if row.kind == .video || row.kind == .gif {
                        Image(systemName: row.kind == .video ? "video.fill" : "play.rectangle.fill")
                            .font(.caption2).foregroundStyle(.white).padding(5).shadow(radius: 2)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityLabel("\(MessagePreview.label(row.kind)) del \(Dates.long(row.ts))")
        }
    }

    private var list: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, row in
                Group {
                    switch section {
                    case .audio:
                        if let a = row.attachment {
                            VStack(alignment: .leading, spacing: 4) {
                                caption(row)
                                AudioBubble(row: row, attachment: a, meta: AnyView(EmptyView()))
                            }
                        }
                    case .documents:
                        if let a = row.attachment {
                            Button { previewURL = model.fileURL(for: a) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(Theme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(a.fileName).lineLimit(2)
                                        caption(row)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    default:
                        VStack(alignment: .leading, spacing: 4) {
                            Text(MessageRowView.attributed(row.text)).font(.subheadline).lineLimit(4)
                            caption(row)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Nella chat") { onJump(row.id) }.tint(Theme.accent)
                }
                .contextMenu { Button("Mostra nella chat") { onJump(row.id) } }
                .onAppear { if index >= items.count - 30 { loadMore() } }
            }
        }
        .listStyle(.plain)
    }

    private func caption(_ row: MessageRow) -> some View {
        Text("\(row.senderName ?? "") · \(Dates.long(row.ts)), \(Dates.time(row.ts))")
            .font(.caption).foregroundStyle(.secondary)
    }
}
