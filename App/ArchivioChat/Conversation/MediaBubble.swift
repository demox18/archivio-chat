import SwiftUI
import QuickLook
import ArchivioCore

/// Il contenuto di un messaggio con allegato: foto, video, GIF, sticker,
/// audio, documento, oppure il riquadro "non disponibile".
struct MediaBubble: View {
    @Environment(AppModel.self) private var model
    let row: MessageRow
    let onOpen: () -> Void
    let meta: AnyView
    @State private var previewURL: URL?

    var body: some View {
        if let attachment = row.attachment {
            switch row.kind {
            case .photo, .video, .gif:
                visual(attachment)
            case .sticker:
                VStack(alignment: row.isMe ? .trailing : .leading, spacing: 2) {
                    ThumbnailView(attachment: attachment, kind: .sticker, pixels: 320, contentMode: .fit)
                        .frame(width: 130, height: 130)
                        .onTapGesture(perform: onOpen)
                        .accessibilityLabel("Sticker")
                    meta
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.pill.opacity(0.9), in: Capsule())
                }
            case .audio:
                AudioBubble(row: row, attachment: attachment, meta: meta)
            default:
                document(attachment)
            }
        } else {
            missing
        }
    }

    private func visual(_ attachment: AttachmentInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ThumbnailView(attachment: attachment, kind: row.kind)
                .frame(width: 236, height: 236)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    if row.kind == .video {
                        Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                            .frame(width: 52, height: 52).background(.black.opacity(0.45), in: Circle())
                    } else if row.kind == .gif {
                        Text("GIF").font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.45), in: Capsule())
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if row.text.isEmpty {
                        meta.colorScheme(.dark)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.4), in: Capsule())
                            .padding(6)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .accessibilityLabel(MessagePreview.label(row.kind))
            if !row.text.isEmpty {
                HStack(alignment: .bottom) {
                    Text(MessageRowView.attributed(row.text)).font(.body)
                    Spacer(minLength: 6)
                    meta
                }
                .padding(.horizontal, 6).padding(.bottom, 2)
                .frame(width: 236, alignment: .leading)
            }
        }
    }

    private func document(_ attachment: AttachmentInfo) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                previewURL = model.fileURL(for: attachment)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.fileName).font(.subheadline).lineLimit(2).multilineTextAlignment(.leading)
                        Text(ByteCountFormatter.string(fromByteCount: attachment.byteSize, countStyle: .file))
                            .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 220, alignment: .leading)
            }
            .buttonStyle(.plain)
            if !row.text.isEmpty { Text(row.text).font(.body).frame(width: 220, alignment: .leading) }
            meta
        }
        .quickLookPreview($previewURL)
    }

    private var missing: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: MessagePreview.icon(row.kind) ?? "paperclip")
                Text("\(MessagePreview.label(row.kind)) non disponibile").font(.subheadline)
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 12).padding(.vertical, 14)
            .frame(minWidth: 200)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.secondaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if !row.text.isEmpty { Text(row.text).font(.body).frame(maxWidth: 220, alignment: .leading) }
            meta
        }
        .accessibilityLabel("\(MessagePreview.label(row.kind)) non disponibile: il file non è stato importato")
    }
}

/// Messaggio vocale con riproduzione.
struct AudioBubble: View {
    @Environment(AppModel.self) private var model
    let row: MessageRow
    let attachment: AttachmentInfo
    let meta: AnyView
    @State private var duration: TimeInterval?

    private var url: URL? { model.playableURL(for: attachment) }
    private var isCurrent: Bool { model.audio.currentID == row.id }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    if let url { model.audio.toggle(id: row.id, url: url) }
                } label: {
                    Image(systemName: isCurrent && model.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(url == nil ? Theme.secondaryText : Theme.accent)
                .disabled(url == nil)
                .accessibilityLabel(isCurrent && model.audio.isPlaying ? "Pausa" : "Riproduci messaggio vocale")

                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: Binding(
                        get: { isCurrent ? model.audio.progress : 0 },
                        set: { model.audio.seek(id: row.id, to: $0) }), in: 0...1)
                        .disabled(!isCurrent)
                        .tint(Theme.accent)
                    Text(url == nil ? "Audio non riproducibile" : (duration.map(Dates.duration) ?? "–:––"))
                        .font(.caption2).foregroundStyle(Theme.secondaryText).monospacedDigit()
                }
                Image(systemName: "mic.fill").font(.footnote).foregroundStyle(Theme.accent)
            }
            .frame(width: 230)
            meta
        }
        .task(id: attachment.sha256) {
            if let url { duration = await model.audio.duration(of: url) }
        }
    }
}
