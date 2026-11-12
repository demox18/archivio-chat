import SwiftUI
import UIKit
import ImageIO
import ArchivioCore

/// Miniature di foto, video e sticker: in memoria e su disco nella cartella
/// delle cache (ricostruibili, quindi il sistema può cancellarle).
final class ThumbnailCache: @unchecked Sendable {
    private let media: MediaStore?
    private let directory: URL
    private let memory = NSCache<NSString, UIImage>()
    private let queue = OperationQueue()

    init(media: MediaStore?, directory: URL) {
        self.media = media
        self.directory = directory
        memory.countLimit = 400
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cached(hash: String, pixels: Int) -> UIImage? {
        memory.object(forKey: "\(hash)-\(pixels)" as NSString)
    }

    func image(hash: String, ext: String, kind: MessageKind, pixels: Int) async -> UIImage? {
        let key = "\(hash)-\(pixels)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        guard let media else { return nil }
        let source = media.url(forHash: hash, ext: ext)
        // Gli sticker hanno la trasparenza: PNG. Il resto JPEG, più leggero.
        let keepAlpha = kind == .sticker
        let file = directory.appendingPathComponent("\(hash)-\(pixels).\(keepAlpha ? "png" : "jpg")")
        return await withCheckedContinuation { continuation in
            queue.addOperation { [memory] in
                var result: UIImage?
                if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                    result = img
                } else if let cg = Thumbnailer.thumbnail(for: source, kind: kind, maxPixel: pixels) {
                    let img = UIImage(cgImage: cg)
                    result = img
                    let data = keepAlpha ? img.pngData() : img.jpegData(compressionQuality: 0.8)
                    try? data?.write(to: file, options: .atomic)
                }
                if let result { memory.setObject(result, forKey: key) }
                continuation.resume(returning: result)
            }
        }
    }

    func clearDisk() {
        memory.removeAllObjects()
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func diskUsage() -> Int64 {
        var total: Int64 = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Miniatura di un allegato, caricata quando compare.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var model
    let attachment: AttachmentInfo
    let kind: MessageKind
    var pixels = 480
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(kind == .sticker ? Color.clear : Theme.missing)
            }
        }
        .task(id: attachment.sha256) {
            if let hit = model.thumbnails.cached(hash: attachment.sha256, pixels: pixels) { image = hit; return }
            image = await model.thumbnails.image(hash: attachment.sha256, ext: attachment.ext, kind: kind, pixels: pixels)
        }
    }
}

/// Immagine animata (sticker WebP, GIF) per il visualizzatore.
enum AnimatedImage {
    static func load(_ url: URL, maxFrames: Int = 120) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(contentsOfFile: url.path) }
        var frames: [UIImage] = []
        var duration: TimeInterval = 0
        for i in 0..<min(count, maxFrames) {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(delay, 0.02)
        }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
