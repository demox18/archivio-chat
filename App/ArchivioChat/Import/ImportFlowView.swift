import SwiftUI
import ArchivioCore

struct ImportFlowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]
    @State private var vm: ImportViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    content(vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Importa chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let vm, canClose(vm) {
                        Button("Chiudi") { vm.release(); dismiss() }
                    }
                }
            }
        }
        .onAppear {
            guard vm == nil else { return }
            let created = ImportViewModel(urls: urls, model: model)
            vm = created
            created.start()
        }
    }

    private func canClose(_ vm: ImportViewModel) -> Bool {
        if case .applying = vm.phase { return false }
        return true
    }

    @ViewBuilder
    private func content(_ vm: ImportViewModel) -> some View {
        switch vm.phase {
        case .reading:
            WaitingView(title: "Lettura del file", detail: vm.currentURL.lastPathComponent)
        case .choosing:
            DestinationView(vm: vm)
        case .analyzing:
            WaitingView(title: "Confronto con l'archivio", detail: "Nessun dato viene ancora modificato.")
        case .preview(let plan):
            PreviewView(vm: vm, plan: plan)
        case .applying(let value):
            VStack(spacing: 16) {
                ProgressView(value: value).padding(.horizontal, 40)
                Text("Importazione in corso").font(.headline)
                Text("Non chiudere l'app. Se qualcosa va storto, l'archivio resta com'era.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        case .finished(let summary):
            ResultView(vm: vm, summary: summary) { dismiss() }
        case .failed(let message):
            ContentUnavailableView {
                Label("Importazione non riuscita", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message + "\n\nNessun dato è stato modificato.")
            } actions: {
                if vm.hasNext {
                    Button("Passa al file successivo") { _ = vm.next() }.buttonStyle(.borderedProminent)
                }
                Button("Chiudi") { vm.release(); dismiss() }
            }
        }
    }
}

private struct WaitingView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }
}

/// Dove va il file: una chat nuova o una già in archivio, e chi è chi.
private struct DestinationView: View {
    @Environment(AppModel.self) private var model
    @Bindable var vm: ImportViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("File", value: vm.currentURL.lastPathComponent)
                if let s = vm.suggestion {
                    LabeledContent("Messaggi nel file", value: s.messageCount.formatted())
                    LabeledContent("Mittenti", value: s.senders.joined(separator: ", "))
                }
            } header: {
                if !vm.fileLabel.isEmpty { Text(vm.fileLabel) }
            }

            Section {
                Picker("Importa in", selection: $vm.destination) {
                    Text("Nuova chat").tag(Int64?.none)
                    ForEach(model.chats) { chat in
                        Text(chat.title).tag(Int64?.some(chat.id))
                    }
                }
            } header: {
                Text("Destinazione")
            } footer: {
                if vm.suggestion?.matchedConversationID != nil, vm.destination == vm.suggestion?.matchedConversationID {
                    Text("Proposta automatica: questa chat conosce già uno dei mittenti.")
                } else if vm.destination != nil {
                    Text("I messaggi del file verranno uniti a quelli già presenti. Nulla di ciò che c'è viene cancellato o modificato.")
                }
            }

            if vm.destination == nil {
                Section("Nuova chat") {
                    TextField("Nome della chat", text: $vm.title)
                    Picker("Chi sei tu?", selection: $vm.me) {
                        Text("Non indicare").tag(String?.none)
                        ForEach(vm.suggestion?.senders ?? [], id: \.self) { name in
                            Text(name).tag(String?.some(name))
                        }
                    }
                }
            } else if let info = vm.destinationInfo, !vm.unknownSenders.isEmpty {
                Section {
                    ForEach(vm.unknownSenders, id: \.self) { name in
                        Picker(name, selection: Binding(
                            get: { vm.mapping[name] ?? .unset },
                            set: { vm.mapping[name] = $0 })) {
                            Text("Scegli…").tag(MappingChoice.unset)
                            ForEach(info.participants) { p in
                                Text(p.isMe ? "\(p.displayName) (tu)" : p.displayName).tag(MappingChoice.participant(p.id))
                            }
                            Text("Persona nuova").tag(MappingChoice.newPerson)
                        }
                    }
                } header: {
                    Text("Chi sono questi nomi?")
                } footer: {
                    Text("Nel file compaiono nomi che questa chat non conosce. Indica a chi corrispondono: serve a riconoscere i messaggi già presenti.")
                }
            }

            Section {
                Button("Analizza") { vm.analyze() }
                    .frame(maxWidth: .infinity)
                    .disabled(!vm.canAnalyze)
            } footer: {
                Text("L'analisi non modifica nulla: mostra un riepilogo da confermare.")
            }
        }
    }
}

/// Il riepilogo da confermare prima che qualcosa venga scritto.
struct PreviewView: View {
    @Bindable var vm: ImportViewModel
    let plan: ImportPlan

    private var s: ImportSummary { plan.summary }

    var body: some View {
        Form {
            Section("Messaggi") {
                row("Nel file", s.totalInFile)
                row("Già presenti in archivio", s.alreadyPresent)
                row("Nuovi da aggiungere", s.newMessages, highlight: true)
                if s.possibleDuplicates > 0 {
                    row("Possibili doppioni (conservati)", s.possibleDuplicates, warning: true)
                }
            }
            Section {
                row("Foto", s.photos)
                row("Video e GIF", s.videos)
                row("Sticker", s.stickers)
                row("Audio", s.audios)
                row("Documenti", s.documents)
                if s.attachmentsToLink > 0 { row("Da collegare a messaggi esistenti", s.attachmentsToLink, highlight: true) }
                if s.missingAttachments > 0 { row("Citati ma non presenti nel file", s.missingAttachments, warning: true) }
            } header: {
                Text("Allegati trovati")
            }
            Section("Periodo") {
                LabeledContent("Dal", value: Dates.long(s.firstTS))
                LabeledContent("Al", value: Dates.long(s.lastTS))
                LabeledContent("Sovrapposizione con l'archivio", value: s.overlaps ? "Sì" : "No")
            }
            if !notes.isEmpty {
                Section("Da sapere") {
                    ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.footnote) }
                }
            }
            Section {
                Button("Conferma importazione") { vm.confirm(plan) }
                    .frame(maxWidth: .infinity).fontWeight(.semibold)
                    .disabled(nothingToDo)
                Button("Torna indietro") { vm.backToChoice() }.frame(maxWidth: .infinity)
            } footer: {
                Text(nothingToDo ? "Il file non contiene nulla che non sia già in archivio."
                     : "I messaggi già presenti non vengono toccati. L'importazione si può annullare dalla scheda della chat.")
            }
        }
    }

    private var nothingToDo: Bool { s.newMessages == 0 && s.attachmentsToLink == 0 }

    private var notes: [String] {
        var out: [String] = []
        if s.unrecognizedLines > 0 {
            out.append("\(s.unrecognizedLines) righe all'inizio del file non sono state riconosciute: vengono conservate come nota di servizio.")
        }
        if !s.newParticipants.isEmpty, vm.destination != nil {
            out.append("Nuovi partecipanti: \(s.newParticipants.joined(separator: ", ")).")
        }
        if s.possibleDuplicates > 0 {
            out.append("I possibili doppioni vengono aggiunti e contrassegnati: meglio un doppione che un messaggio perso.")
        }
        if s.missingAttachments > 0 {
            out.append("I messaggi con allegato mancante restano in archivio; l'allegato si collegherà se importi un file che lo contiene.")
        }
        return out
    }

    private func row(_ label: String, _ value: Int, highlight: Bool = false, warning: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value.formatted())
                .fontWeight(highlight ? .semibold : .regular)
                .foregroundStyle(warning ? Color.orange : (highlight ? Theme.accent : Color.secondary))
                .monospacedDigit()
        }
    }
}

private struct ResultView: View {
    @Bindable var vm: ImportViewModel
    let summary: ImportSummary
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text("Importazione completata").font(.title3.weight(.semibold))
            Text("\(summary.newMessages.formatted()) messaggi aggiunti, \(summary.attachmentsToLink.formatted()) allegati collegati a messaggi esistenti.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            if vm.hasNext {
                Button("File successivo") { _ = vm.next() }.buttonStyle(.borderedProminent)
            }
            Button("Fine") { vm.release(); close() }
                .buttonStyle(.bordered)
        }
    }
}
