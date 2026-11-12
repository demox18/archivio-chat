import Foundation
import CryptoKit

/// File multimediali, nominati con la loro impronta SHA-256: lo stesso
/// contenuto importato più volte occupa spazio una volta sola.
public final class MediaStore: Sendable {
    public let root: URL
    private var staging: URL { root.appendingPathComponent(".staging") }

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".staging"),
                                                withIntermediateDirectories: true)
    }

    public func url(forHash hash: String, ext: String) -> URL {
        let name = ext.isEmpty ? hash : "\(hash).\(ext.lowercased())"
        return root.appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(name)
    }

    /// Un percorso nuovo nella cartella di lavoro, dove estrarre un file prima di archiviarlo.
    public func newStagingURL() -> URL {
        staging.appendingPathComponent(UUID().uuidString)
    }

    func clearStaging() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    /// Sposta il file nell'archivio. Se un file con la stessa impronta esiste già,
    /// quello nuovo viene scartato e `existed` è vero.
    public func ingest(fileAt source: URL, ext: String) throws -> (hash: String, size: Int64, existed: Bool) {
        let fm = FileManager.default
        let (hash, size) = try Self.sha256(of: source)
        let dest = url(forHash: hash, ext: ext)
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: source)
            return (hash, size, true)
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: source, to: dest)
        return (hash, size, false)
    }

    /// Copia (senza toccare l'originale) e archivia.
    public func ingest(copying source: URL, ext: String) throws -> (hash: String, size: Int64, existed: Bool) {
        let tmp = newStagingURL()
        try FileManager.default.copyItem(at: source, to: tmp)
        return try ingest(fileAt: tmp, ext: ext)
    }

    public static func sha256(of url: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// Rimuove i file la cui impronta non è più citata. Restituisce quanti ne ha tolti.
    @discardableResult
    public func removeOrphans(referenced: Set<String>) throws -> Int {
        let fm = FileManager.default
        var removed = 0
        for bucket in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard bucket.lastPathComponent != ".staging", bucket.hasDirectoryPath else { continue }
            for file in try fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil) {
                let hash = file.deletingPathExtension().lastPathComponent
                if !referenced.contains(hash) {
                    try? fm.removeItem(at: file)
                    removed += 1
                }
            }
        }
        return removed
    }

    /// Tutti i file presenti (esclusa la cartella di lavoro). Serve ai test e alle impostazioni.
    public func allFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for bucket in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard bucket.lastPathComponent != ".staging", bucket.hasDirectoryPath else { continue }
            out.append(contentsOf: (try? fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: nil)) ?? [])
        }
        return out
    }

    public func stagingFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
    }
}
