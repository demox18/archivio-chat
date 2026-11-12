import Foundation
import ImageIO
import AVFoundation

/// Miniature di foto, sticker e video. Sono ricostruibili in ogni momento,
/// quindi l'app le tiene nella cache e non nell'archivio.
public enum Thumbnailer {
    public static func thumbnail(for url: URL, kind: MessageKind, maxPixel: Int) -> CGImage? {
        switch kind {
        case .video, .gif:
            return videoFrame(url, maxPixel: maxPixel) ?? imageThumbnail(url, maxPixel: maxPixel)
        default:
            return imageThumbnail(url, maxPixel: maxPixel)
        }
    }

    private static func imageThumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func videoFrame(_ url: URL, maxPixel: Int) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// Dimensioni in pixel di un'immagine, senza decodificarla.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { return CGSize(width: h, height: w) }
        return CGSize(width: w, height: h)
    }
}
