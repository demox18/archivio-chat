import SwiftUI
import AVKit
import ImageIO
import ArchivioCore

/// Visualizzatore a schermo intero: foto con zoom, video, GIF e sticker.
struct MediaViewer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let items: [MessageRow]
    let onShowInChat: (Int64) -> Void
    @State private var index: Int

    init(items: [MessageRow], startIndex: Int, onShowInChat: @escaping (Int64) -> Void) {
        self.items = items
        self.onShowInChat = onShowInChat
        _index = State(initialValue: startIndex)
    }

    private var current: MessageRow? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, row in
                    page(row, active: i == index).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Chiudi")
            Spacer()
            if let row = current {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.senderName ?? "").font(.subheadline.weight(.semibold))
                    Text("\(Dates.long(row.ts)), \(Dates.time(row.ts))").font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.top, 8)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let text = current?.text, !text.isEmpty {
                Text(text).font(.subheadline).foregroundStyle(.white).lineLimit(4)
                    .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                if items.count > 1 {
                    Text("\(index + 1) di \(items.count)").font(.caption).monospacedDigit()
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let row = current {
                    Button { onShowInChat(row.id) } label: {
                        Label("Mostra nella chat", systemImage: "text.bubble").font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    @ViewBuilder
    private func page(_ row: MessageRow, active: Bool) -> some View {
        if let attachment = row.attachment, let url = model.fileURL(for: attachment) {
            switch row.kind {
            case .video, .gif:
                VideoPage(url: url, loop: row.kind == .gif, active: active)
            case .sticker:
                AnimatedImageView(url: url).padding(40)
            default:
                ZoomableImage(url: url)
            }
        } else {
            ContentUnavailableView("Contenuto non disponibile", systemImage: "photo")
        }
    }
}

private struct VideoPage: View {
    let url: URL
    let loop: Bool
    let active: Bool
    @State private var player: AVPlayer?
    @State private var observer: NSObjectProtocol?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let p = AVPlayer(url: url)
                p.isMuted = loop
                player = p
                if loop {
                    observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                        p.seek(to: .zero)
                        p.play()
                    }
                }
                if active { try? AVAudioSession.sharedInstance().setCategory(.playback); p.play() }
            }
            .onChange(of: active) { _, now in now ? player?.play() : player?.pause() }
            .onDisappear {
                player?.pause()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                player = nil
            }
    }
}

/// Sticker e immagini animate (WebP, GIF). Con "Riduci movimento" attivo resta ferma.
private struct AnimatedImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let url = url
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIAccessibility.isReduceMotionEnabled ? UIImage(contentsOfFile: url.path) : AnimatedImage.load(url)
            DispatchQueue.main.async { view.image = image }
        }
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}

/// Foto con zoom a due dita e doppio tocco.
private struct ZoomableImage: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scroll = scroll
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        let url = url
        DispatchQueue.global(qos: .userInitiated).async {
            // Si decodifica a una dimensione ragionevole: una foto enorme non deve esaurire la memoria.
            var image: UIImage?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                kCGImageSourceCreateThumbnailWithTransform: true,
                                                kCGImageSourceThumbnailMaxPixelSize: 3200]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { image = UIImage(cgImage: cg) }
            }
            DispatchQueue.main.async { imageView.image = image }
        }
        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}
