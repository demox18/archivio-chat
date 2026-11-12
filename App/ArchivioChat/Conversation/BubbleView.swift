import SwiftUI
import UIKit
import ArchivioCore

/// Un messaggio nella conversazione: fumetto a destra (mio) o a sinistra,
/// oppure riga grigia centrata per chiamate e messaggi di servizio.
struct MessageRowView: View {
    let row: MessageRow
    let startsGroup: Bool
    let showSender: Bool
    let highlighted: Bool
    let expanded: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onStar: () -> Void
    let onInfo: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            switch row.kind {
            case .system, .call:
                servicePill
            default:
                HStack(spacing: 0) {
                    if row.isMe { Spacer(minLength: 48) }
                    bubble
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 14))
                        .contextMenu { menu }
                        .onTapGesture(perform: onTap)
                    if !row.isMe { Spacer(minLength: 48) }
                }
            }
            if expanded {
                Text(Dates.full(row.ts))
                    .font(.caption2).foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: row.kind == .system || row.kind == .call ? .center : (row.isMe ? .trailing : .leading))
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
        }
        .background(highlighted ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Fumetto

    @ViewBuilder
    private var bubble: some View {
        if row.kind == .sticker, row.attachment != nil {
            MediaBubble(row: row, onOpen: onOpen, meta: AnyView(metaView(onMedia: false)))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if showSender, !row.isMe, startsGroup, let name = row.senderName {
                    Text(name).font(.footnote.weight(.semibold)).foregroundStyle(Theme.color(for: name))
                }
                content
            }
            .padding(.horizontal, row.kind.isMedia && row.attachment != nil && row.kind != .audio && row.kind != .document ? 4 : 10)
            .padding(.vertical, row.kind.isMedia && row.attachment != nil && row.kind != .audio && row.kind != .document ? 4 : 6)
            .background(row.isMe ? Theme.bubbleMine : Theme.bubbleTheirs,
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .deleted:
            textWithMeta(Text(Image(systemName: "nosign")) + Text(" " + row.text).italic(), secondary: true)
        case .text:
            textWithMeta(Text(Self.attributed(row.text)), secondary: false)
        default:
            MediaBubble(row: row, onOpen: onOpen, meta: AnyView(metaView(onMedia: false)))
        }
    }

    /// Il testo con l'orario in basso a destra, come su WhatsApp: uno spazio
    /// invisibile in coda al testo riserva il posto all'orario.
    private func textWithMeta(_ text: Text, secondary: Bool) -> some View {
        (text + Text("  " + metaPlaceholder).font(.caption2).foregroundColor(.clear))
            .font(.body)
            .foregroundStyle(secondary ? Theme.secondaryText : Color.primary)
            .overlay(alignment: .bottomTrailing) { metaView(onMedia: false).offset(y: 2) }
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metaPlaceholder: String {
        (row.starred ? "★  " : "") + (row.edited ? "modificato  " : "") + (row.possibleDuplicate ? "⧉  " : "") + "00:00"
    }

    func metaView(onMedia: Bool) -> some View {
        HStack(spacing: 3) {
            if row.possibleDuplicate {
                Image(systemName: "doc.on.doc").font(.system(size: 9)).accessibilityLabel("Possibile doppione")
            }
            if row.starred {
                Image(systemName: "star.fill").font(.system(size: 9)).accessibilityLabel("Preferito")
            }
            if row.edited { Text("modificato") }
            Text(Dates.time(row.ts))
        }
        .font(.caption2)
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(1)
    }

    // MARK: - Chiamate e messaggi di servizio

    private var servicePill: some View {
        HStack(spacing: 5) {
            if row.kind == .call { Image(systemName: "phone.fill").font(.caption2) }
            Text(row.text).font(.caption)
            if row.kind == .call { Text(Dates.time(row.ts)).font(.caption2) }
        }
        .foregroundStyle(Theme.secondaryText)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.pill, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .onTapGesture(perform: onTap)
    }

    // MARK: - Menu (pressione prolungata)

    @ViewBuilder
    private var menu: some View {
        Button(action: onStar) {
            Label(row.starred ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                  systemImage: row.starred ? "star.slash" : "star")
        }
        if !row.text.isEmpty {
            Button { UIPasteboard.general.string = row.text } label: { Label("Copia", systemImage: "doc.on.doc") }
        }
        Button(action: onInfo) { Label("Info", systemImage: "info.circle") }
    }

    // MARK: - Link nel testo

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard text.contains("http") || text.contains("www."), let detector else { return out }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, let r = Range(match.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }
}
