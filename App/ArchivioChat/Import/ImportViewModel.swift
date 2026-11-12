import SwiftUI
import Observation
import ArchivioCore

/// A chi corrisponde un nome del file, nella schermata di abbinamento.
enum MappingChoice: Hashable {
    case unset
    case participant(Int64)
    case newPerson
}

/// Guida l'importazione di uno o più file, uno alla volta:
/// lettura → destinazione → anteprima → conferma.
@MainActor
@Observable
final class ImportViewModel {
    enum Phase {
        case reading
        case choosing
        case analyzing
        case preview(ImportPlan)
        case applying(Double)
        case finished(ImportSummary)
        case failed(String)
    }

    let urls: [URL]
    private let model: AppModel
    private(set) var index = 0
    private(set) var phase: Phase = .reading
    private(set) var suggestion: TargetSuggestion?
    private var source: (any ImportSource)?
    private var accessing = false

    // Scelte dell'utente
    var destination: Int64? { didSet { loadDestination() } }
    var title = ""
    var me: String?
    var mapping: [String: MappingChoice] = [:]
    private(set) var destinationInfo: ConversationInfo?
    private(set) var unknownSenders: [String] = []

    init(urls: [URL], model: AppModel) {
        self.urls = urls
        self.model = model
    }

    var currentURL: URL { urls[index] }
    var fileLabel: String { urls.count > 1 ? "File \(index + 1) di \(urls.count)" : "" }
    var hasNext: Bool { index + 1 < urls.count }

    func start() {
        guard let importer = model.importer else { phase = .failed("Archivio non disponibile."); return }
        phase = .reading
        suggestion = nil
        source = nil
        let url = currentURL
        accessing = url.startAccessingSecurityScopedResource()
        Task {
            do {
                let (src, sug) = try await Task.detached(priority: .userInitiated) { () -> (any ImportSource, TargetSuggestion) in
                    let src: any ImportSource = url.pathExtension.lowercased() == "zip"
                        ? try ZipSource(url: url) : TextFileSource(url: url)
                    return (src, try importer.suggest(src))
                }.value
                source = src
                suggestion = sug
                title = sug.suggestedTitle
                me = sug.likelyMe
                destination = sug.matchedConversationID
                loadDestination()
                phase = .choosing
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    private func loadDestination() {
        guard let suggestion else { return }
        guard let destination, let info = try? model.store?.conversationInfo(id: destination) else {
            destinationInfo = nil
            unknownSenders = []
            return
        }
        destinationInfo = info
        let known = Set(info.participants.flatMap(\.aliases))
        unknownSenders = suggestion.senders.filter { !known.contains($0) }
        var next: [String: MappingChoice] = [:]
        let mine = info.participants.first(where: \.isMe)
        for name in unknownSenders {
            if let old = mapping[name], old != .unset, isValid(old, in: info) {
                next[name] = old
            } else if name == suggestion.likelyMe, let mine {
                next[name] = .participant(mine.id)
            } else {
                next[name] = .unset
            }
        }
        mapping = next
    }

    private func isValid(_ choice: MappingChoice, in info: ConversationInfo) -> Bool {
        if case .participant(let id) = choice { return info.participants.contains { $0.id == id } }
        return true
    }

    var canAnalyze: Bool {
        if destination == nil { return !title.trimmingCharacters(in: .whitespaces).isEmpty }
        return unknownSenders.allSatisfy { mapping[$0] != nil && mapping[$0] != .unset }
    }

    func analyze() {
        guard let importer = model.importer, let source else { return }
        let target: ImportTarget
        if let destination {
            var senders: [String: ParticipantChoice] = [:]
            for name in unknownSenders {
                switch mapping[name] ?? .unset {
                case .participant(let id): senders[name] = .existing(id)
                case .newPerson, .unset: senders[name] = .new(isMe: false)
                }
            }
            target = .existing(conversationID: destination, senders: senders)
        } else {
            target = .newConversation(title: title.trimmingCharacters(in: .whitespaces), me: me)
        }
        phase = .analyzing
        Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) { try importer.analyze(source, target: target) }.value
                phase = .preview(plan)
            } catch {
                phase = .failed(Self.describe(error))
            }
        }
    }

    func confirm(_ plan: ImportPlan) {
        guard let importer = model.importer else { return }
        phase = .applying(0)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { [weak self] in
                    var last = 0.0
                    try importer.apply(plan) { value in
                        // Aggiorna la barra al più cento volte.
                        guard value - last >= 0.01 || value >= 1 else { return }
                        last = value
                        Task { @MainActor in
                            if case .applying = self?.phase { self?.phase = .applying(value) }
                        }
                    }
                }.value
                model.reload()
                phase = .finished(plan.summary)
            } catch {
                model.reload()
                phase = .failed(Self.describe(error))
            }
        }
    }

    func backToChoice() { phase = .choosing }

    /// Passa al file successivo. Restituisce falso se non ce ne sono altri.
    func next() -> Bool {
        release()
        guard hasNext else { return false }
        index += 1
        mapping = [:]
        start()
        return true
    }

    func release() {
        if accessing { currentURL.stopAccessingSecurityScopedResource() }
        accessing = false
        source = nil
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
