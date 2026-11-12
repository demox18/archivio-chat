import Foundation
import ZIPFoundation

/// Un file scelto dall'utente. Viene solo letto, mai modificato.
public protocol ImportSource: Sendable {
    var displayName: String { get }
    func fileHash() throws -> String
    func chatText() throws -> Data
    /// Nomi (senza cartelle) degli allegati contenuti nella sorgente.
    var attachmentNames: [String] { get }
    func attachmentSize(named name: String) -> Int64
    func extractAttachment(named name: String, to url: URL) throws
}

public struct TextFileSource: ImportSource {
    public let url: URL
    public init(url: URL) { self.url = url }

    public var displayName: String { url.lastPathComponent }
    public func fileHash() throws -> String { try MediaStore.sha256(of: url).hash }
    public func chatText() throws -> Data { try Data(contentsOf: url, options: .mappedIfSafe) }
    public var attachmentNames: [String] { [] }
    public func attachmentSize(named name: String) -> Int64 { 0 }
    public func extractAttachment(named name: String, to url: URL) throws {
        throw ImportError.unreadable("Un file di testo non contiene allegati.")
    }
}

/// Esportazione ZIP: il file della chat più gli allegati. Le voci si leggono
/// una alla volta, senza caricare l'archivio in memoria.
public final class ZipSource: ImportSource, @unchecked Sendable {
    public let url: URL
    private let archive: Archive
    private let lock = NSLock()
    private var chatEntry: Entry?
    private var entries: [String: Entry] = [:]
    public private(set) var attachmentNames: [String] = []

    public init(url: URL) throws {
        self.url = url
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ImportError.unreadable("Il file ZIP non si apre: potrebbe essere danneggiato.")
        }
        var textEntries: [Entry] = []
        for entry in archive where entry.type == .file {
            let path = entry.path
            // Una voce che prova a uscire dalla cartella viene ignorata.
            if path.split(separator: "/").contains("..") { continue }
            let name = (path as NSString).lastPathComponent
            if name.isEmpty || name.hasPrefix(".") || path.hasPrefix("__MACOSX/") { continue }
            if name.lowercased().hasSuffix(".txt") {
                textEntries.append(entry)
            } else if entries[name] == nil {   // a nomi ripetuti vince la prima voce
                entries[name] = entry
                attachmentNames.append(name)
            }
        }
        chatEntry = textEntries.first { ($0.path as NSString).lastPathComponent == "_chat.txt" } ?? textEntries.first
        // Altri file di testo oltre alla chat sono documenti allegati.
        for entry in textEntries where entry.path != chatEntry?.path {
            let name = (entry.path as NSString).lastPathComponent
            if entries[name] == nil { entries[name] = entry; attachmentNames.append(name) }
        }
    }

    public var displayName: String { url.lastPathComponent }
    public func fileHash() throws -> String { try MediaStore.sha256(of: url).hash }

    public func chatText() throws -> Data {
        guard let chatEntry else { throw ImportError.noChatFile }
        var data = Data()
        lock.lock(); defer { lock.unlock() }
        _ = try archive.extract(chatEntry) { data.append($0) }
        return data
    }

    public func attachmentSize(named name: String) -> Int64 {
        Int64(entries[name]?.uncompressedSize ?? 0)
    }

    public func extractAttachment(named name: String, to url: URL) throws {
        guard let entry = entries[name] else {
            throw ImportError.unreadable("Allegato non trovato nello ZIP: \(name)")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        lock.lock(); defer { lock.unlock() }
        _ = try archive.extract(entry, bufferSize: 1 << 18) { try handle.write(contentsOf: $0) }
    }
}
