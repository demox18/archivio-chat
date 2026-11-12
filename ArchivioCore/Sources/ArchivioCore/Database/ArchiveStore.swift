import Foundation
import GRDB

/// L'archivio su disco: il database e la cartella dei file multimediali.
public final class ArchiveStore: @unchecked Sendable {
    public let directory: URL
    public let db: DatabasePool
    public let media: MediaStore

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        db = try DatabasePool(path: directory.appendingPathComponent("archivio.sqlite").path, configuration: config)
        try Schema.migrator.migrate(db)
        media = try MediaStore(root: directory.appendingPathComponent("media"))
        // Pulizia dopo un'eventuale chiusura improvvisa durante un'importazione.
        media.clearStaging()
        _ = try? media.removeOrphans(referenced: referencedHashes())
    }

    /// Impronte di tutti i file ancora citati dal database.
    public func referencedHashes() throws -> Set<String> {
        try db.read { db in
            var set = Set(try String.fetchAll(db, sql: "SELECT DISTINCT sha256 FROM attachment"))
            set.formUnion(try String.fetchAll(db, sql: "SELECT avatar_hash FROM conversation WHERE avatar_hash IS NOT NULL"))
            return set
        }
    }

    /// Spazio occupato da database e media, in byte.
    public func diskUsage() -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        if let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) {
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: Set(keys))
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
            }
        }
        return total
    }
}
