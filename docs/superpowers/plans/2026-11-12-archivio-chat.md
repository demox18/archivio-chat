# Archivio Chat — piano di implementazione

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** un'app iPhone che importa, unisce senza perdite e fa consultare le chat esportate da WhatsApp, con interfaccia tipo WhatsApp.

**Architecture:** un pacchetto Swift `ArchivioCore` (parsing, database, fusione, media), compilabile e provabile anche su macOS con `swift test`, e un'app SwiftUI `ArchivioChat` che lo usa. L'importazione è in due fasi: analisi senza scritture, poi applicazione in un'unica transazione.

**Tech Stack:** Swift 6 (language mode 5), SwiftUI, GRDB 7 (SQLite + FTS5), ZIPFoundation 0.9, ImageIO, AVFoundation, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-12-archivio-chat-design.md`

## Global Constraints

- iOS 17 o successivo, solo iPhone; il pacchetto dichiara anche macOS 14 per i test.
- Nessun codice di rete, in nessun modulo.
- I file scelti dall'utente si leggono e si copiano, non si modificano mai.
- La fusione non cancella righe e non modifica testo, data o mittente di messaggi esistenti; l'unica scrittura su dati esistenti è una nuova riga `attachment`.
- Ogni applicazione e ogni annullamento avvengono in una sola transazione.
- Testi dell'interfaccia in italiano. Nessun testo in movimento continuo.
- Nei test solo dati inventati; i file veri dell'utente servono solo alla verifica finale in locale e non entrano nel repository.
- Tutti i comandi usano `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- I test che creano cartelle temporanee le cancellano alla fine.
- Istanti: `Int64`, secondi dal 1970 calcolati leggendo i componenti del file come se fossero UTC (nessuna conversione di fuso, né in scrittura né in lettura).

## Review Focus

1. **ZIP molto grande** (750 MB, 7.000 voci): l'estrazione non deve caricare l'archivio in memoria e deve mostrare l'avanzamento. Test nel Task 4.
2. **Nomi dentro lo ZIP** con sottocartelle, `..` o nomi ripetuti: si usa solo l'ultimo componente e non si scrive mai fuori da `media/`. Test nel Task 4.
3. **Testo non standard**: BOM, solo LF, byte non UTF-8, righe che sembrano intestazioni dentro un messaggio, mittente con `:` nel nome. Nessuna riga persa. Test nel Task 1.
4. **Errore a metà copia dei file** (disco pieno, file illeggibile): archivio identico a prima e nessun file orfano. Test nel Task 4.
5. **Annullamento con stelle e allegati collegati a messaggi più vecchi**: tornano allo stato precedente esatto. Test nel Task 3 e nel Task 4.

---

## Struttura dei file

```
ArchivioCore/Package.swift
ArchivioCore/Sources/ArchivioCore/
  Parsing/ParsedMessage.swift      tipi: MessageKind, ParsedMessage, ParseResult
  Parsing/Dialect.swift            marcatori italiano/inglese, ordine giorno/mese
  Parsing/ChatParser.swift         testo → ParseResult
  Database/Schema.swift            migrazioni GRDB
  Database/Records.swift           Conversation, Participant, Message, Attachment, ImportBatch
  Database/ArchiveStore.swift      apertura, cartelle, accesso al database
  Database/Queries.swift           elenco chat, pagine di messaggi, ricerca, stelle, raccolta media
  Importing/ImportSource.swift     protocollo + TextFileSource + ZipSource
  Importing/ImportPlan.swift       ImportTarget, ImportSummary, ImportPlan
  Importing/Merger.swift           confronto puro: esistenti + in arrivo → decisioni
  Importing/Importer.swift         suggest, analyze, apply, undo
  Media/MediaStore.swift           file per impronta, pulizia orfani
  Media/OggOpusToCAF.swift         conversione di contenitore dei vocali
  Media/Thumbnailer.swift          miniature con ImageIO / AVAssetImageGenerator
ArchivioCore/Tests/ArchivioCoreTests/
  ParserTests.swift  MergeTests.swift  ImportScenarioTests.swift
  MediaImportTests.swift  QueryTests.swift  OggTests.swift  Fixtures.swift
App/ArchivioChat.xcodeproj
App/ArchivioChat/
  ArchivioChatApp.swift  AppModel.swift  Theme.swift
  Chats/ChatListView.swift  Chats/ChatRow.swift  Chats/AvatarView.swift
  Import/ImportFlowView.swift  Import/ImportViewModel.swift  Import/PreviewView.swift
  Conversation/ConversationView.swift  Conversation/ConversationViewModel.swift
  Conversation/BubbleView.swift  Conversation/MediaBubble.swift  Conversation/AudioBubble.swift
  Info/ConversationInfoView.swift  Info/MediaGalleryView.swift  Info/MediaViewer.swift
  Search/SearchView.swift  Starred/StarredView.swift  Settings/SettingsView.swift
```

---

### Task 1: Pacchetto e parser

**Files:** `Package.swift`, `Parsing/*`, `Tests/.../ParserTests.swift`, `Tests/.../Fixtures.swift`

**Interfaces — Produces:**

```swift
public enum MessageKind: String, Codable, Sendable {
    case text, photo, video, gif, sticker, audio, document, call, deleted, system
    public var isMedia: Bool   // photo, video, gif, sticker, audio, document
}
public struct ParsedMessage: Equatable, Sendable {
    public var ts: Int64
    public var sender: String?          // nil solo per righe senza mittente
    public var kind: MessageKind
    public var text: String             // senza U+200E, senza marcatore di modifica, a capo = "\n"
    public var attachmentName: String?  // nil se testo o media omesso
    public var edited: Bool
    public var line: Int                // 1-based
}
public struct ParseResult: Sendable {
    public var messages: [ParsedMessage]
    public var unrecognizedLines: Int
    public var senders: [String]        // in ordine di prima comparsa
}
public enum ChatParser { public static func parse(_ data: Data) -> ParseResult }
```

Decisioni:
- Intestazione: `^‎?\[(\d{1,2})/(\d{1,2})/(\d{2,4}), (\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s?([AP]M))?\] (.*)$`. Il resto si divide al primo `": "`; se manca ma finisce con `:`, mittente = tutto meno `:`, testo vuoto; altrimenti messaggio `system` senza mittente.
- Ordine giorno/mese: giorno-mese salvo che in tutto il file compaia un secondo campo > 12 e mai un primo campo > 12. Anno a due cifre = 2000 + aa.
- Decodifica: UTF-8 tollerante (`String(decoding:as:)`), BOM rimosso, `\r\n` e `\r` → `\n`.
- Tipo dal nome dell'allegato: contiene `-PHOTO-` → photo, `-VIDEO-` → video, `-GIF-` → gif, `-STICKER-` → sticker, `-AUDIO-` o `-PTT-` → audio; altrimenti per estensione (jpg/jpeg/png/heic → photo, mp4/mov → video, webp → sticker, opus/m4a/mp3/aac → audio), il resto document. Il testo dopo `<allegato: …>` (didascalia) resta in `text`.
- Marcatori in `Dialect` (italiano e inglese): allegato (`allegato`, `attached`); omessi (`immagine omessa`/`image omitted`, `video omesso`/`video omitted`, `audio omesso`/`audio omitted`, `sticker non incluso`/`sticker omitted`, `GIF esclusa`/`GIF omitted`, `documento omesso`/`document omitted`); eliminati (`Hai eliminato questo messaggio.`, `Questo messaggio è stato eliminato.`, `You deleted this message.`, `This message was deleted.`); chiamate (inizia con `Chiamata`, `Videochiamata`, `Voice call`, `Video call`, `Missed`); modifica (`<Questo messaggio è stato modificato>`, `<This message was edited>`). Un testo che inizia con U+200E e non è nessuno dei precedenti → `system`.

- [ ] **Step 1:** `Package.swift` (piattaforme iOS 17 e macOS 14; dipendenze GRDB `from: "7.0.0"`, ZIPFoundation `from: "0.9.19"`; `swiftLanguageModes: [.v5]`).
- [ ] **Step 2:** test che falliscono in `ParserTests`:
  - `testBasicLine`: `[05/08/24, 01:48:41] Ash: ciao\r\n` → 1 messaggio, `ts == 1722822521`, sender `Ash`, kind `.text`, text `ciao`.
  - `testContinuation`: tre righe di cui due senza intestazione → 1 messaggio con `text == "a\nb\nc"`.
  - `testEmptyBody`: `[..] Ash:` → text vuoto, kind `.text`.
  - `testAttachmentKinds`: PHOTO/VIDEO/GIF/STICKER/AUDIO e `relazione.pdf` → kind e `attachmentName` giusti.
  - `testOmitted`: i sei marcatori italiani → kind media, `attachmentName == nil`.
  - `testServiceLines`: chiamata → `.call`, eliminato → `.deleted`, blocco → `.system`.
  - `testEdited`: suffisso tolto dal testo, `edited == true`.
  - `testEnglishMonthFirst`: `[8/22/25, 1:44:05 PM] Ash: hi` → 22 agosto, 13:44:05.
  - `testRobustness` (Review Focus 3): BOM + solo LF + byte `0xFF` + prima riga senza intestazione + riga `[non una data] x` in mezzo a un messaggio + mittente `Dr: Rossi` → nessuna riga persa: la somma delle righe di testo ricostruite è pari alle righe d'ingresso, `unrecognizedLines == 1`.
- [ ] **Step 3:** `swift test --filter ParserTests` → fallisce (tipi assenti).
- [ ] **Step 4:** implementare `ParsedMessage.swift`, `Dialect.swift`, `ChatParser.swift`.
- [ ] **Step 5:** `swift test --filter ParserTests` → verde. Commit.

---

### Task 2: Database

**Files:** `Database/Schema.swift`, `Records.swift`, `ArchiveStore.swift`, test dentro `ImportScenarioTests` (apertura) 

**Interfaces — Produces:**

```swift
public final class ArchiveStore: @unchecked Sendable {
    public let db: DatabasePool
    public let media: MediaStore            // Task 4; qui solo la cartella
    public init(directory: URL) throws      // crea directory, archivio.sqlite, media/
}
```

Schema (migrazione `v1`), tutte le chiavi esterne `ON DELETE CASCADE` salvo dove indicato:

```sql
conversation(id PK, title TEXT NOT NULL, avatar_hash TEXT, created_at INTEGER NOT NULL)
participant(id PK, conversation_id FK, display_name TEXT NOT NULL, is_me INTEGER NOT NULL DEFAULT 0, created_by_batch INTEGER)
participant_alias(id PK, conversation_id FK, participant_id FK, name TEXT NOT NULL, created_by_batch INTEGER, UNIQUE(conversation_id, name))
import_batch(id PK, conversation_id FK, file_name TEXT NOT NULL, file_hash TEXT NOT NULL, created_at INTEGER NOT NULL,
             status TEXT NOT NULL, created_conversation INTEGER NOT NULL DEFAULT 0, summary_json TEXT NOT NULL)
message(id PK, conversation_id FK, participant_id FK NULL, ts INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
        attachment_name TEXT, edited INTEGER NOT NULL, possible_duplicate INTEGER NOT NULL DEFAULT 0,
        batch_id INTEGER NOT NULL REFERENCES import_batch(id), source_line INTEGER NOT NULL, seq INTEGER NOT NULL)
attachment(id PK, message_id FK, file_name TEXT NOT NULL, sha256 TEXT NOT NULL, byte_size INTEGER NOT NULL,
           kind TEXT NOT NULL, playable_hash TEXT, batch_id INTEGER NOT NULL REFERENCES import_batch(id))
star(message_id PK FK, created_at INTEGER NOT NULL)
message_fts  -- FTS5 esterno su message(text), tokenizer unicode61 remove_diacritics 2, trigger di sincronizzazione
INDEX message(conversation_id, ts, seq, id)
INDEX attachment(sha256), attachment(message_id)
```

`seq` = posizione del messaggio nel file d'origine: l'ordine in conversazione è `(ts, batch_id, seq)`, così i messaggi dello stesso secondo restano nell'ordine del file.

- [ ] **Step 1:** test `testStoreOpensAndMigrates`: apre in cartella temporanea, le otto tabelle esistono, `PRAGMA foreign_keys == 1`, riaprire non fallisce.
- [ ] **Step 2:** fallisce → implementare → verde. Commit.

---

### Task 3: Fusione (solo testo)

**Files:** `Importing/ImportSource.swift` (protocollo + `TextFileSource`), `ImportPlan.swift`, `Merger.swift`, `Importer.swift`, `MergeTests.swift`, `ImportScenarioTests.swift`

**Interfaces — Produces:**

```swift
public protocol ImportSource: Sendable {
    var displayName: String { get }
    func fileHash() throws -> String
    func chatText() throws -> Data
    var attachmentNames: [String] { get }                    // nomi base, vuoto per TXT
    func extractAttachment(named: String, to url: URL) throws
}
public struct TextFileSource: ImportSource { public init(url: URL) }

public enum ParticipantChoice: Equatable, Sendable { case existing(Int64), new(isMe: Bool) }
public enum ImportTarget: Sendable {
    case newConversation(title: String, me: String?)
    case existing(conversationID: Int64, senders: [String: ParticipantChoice])
}
public struct ImportSummary: Codable, Equatable, Sendable {
    public var alreadyPresent, newMessages, possibleDuplicates: Int
    public var photos, videos, stickers, audios, documents: Int     // file trovati nella sorgente
    public var attachmentsToLink, missingAttachments: Int
    public var unrecognizedLines: Int
    public var overlaps: Bool                                       // gli intervalli di date si toccano
}
public struct TargetSuggestion: Sendable {
    public var senders: [String]
    public var matchedConversationID: Int64?        // per alias già noto
    public var suggestedTitle: String               // dal nome del file, senza "WhatsApp Chat - " ed estensione
}
public struct ImportPlan: Sendable { public let summary: ImportSummary /* + decisioni interne */ }

public final class Importer {
    public init(store: ArchiveStore)
    public func suggest(_ source: ImportSource) throws -> TargetSuggestion
    public func analyze(_ source: ImportSource, target: ImportTarget) throws -> ImportPlan
    @discardableResult
    public func apply(_ plan: ImportPlan, progress: ((Double) -> Void)? = nil) throws -> Int64   // id importazione
    public func canUndo(conversationID: Int64) throws -> (batchID: Int64, starsLost: Int)?
    public func undoLastImport(conversationID: Int64) throws
    var failureInjection: ((_ step: Int) throws -> Void)?   // interno, per il test 7
}
```

`Merger` è una funzione pura, senza database:

```swift
struct ExistingMessage { id: Int64; ts: Int64; participantKey: Int64?; kind; text; attachmentName: String?; hasFile: Bool; edited: Bool }
struct IncomingMessage { index: Int; parsed: ParsedMessage; participantKey: Int64? /* negativo = partecipante nuovo */ }
enum Decision { case present(existingID: Int64), link(existingID: Int64), insert(possibleDuplicate: Bool) }
static func decide(existing: [ExistingMessage], incoming: [IncomingMessage]) -> [Decision]
```

Algoritmo di `decide`, per ogni gruppo `(ts, participantKey)`:

1. **Non media** (`text, call, deleted, system`): chiave `(kind, testo normalizzato)`. L'occorrenza k-esima in arrivo è `present` se gli esistenti con quella chiave sono più di k; altrimenti passa al punto 3.
2. **Media**, per ogni `kind`: (a) con nome ↔ con stesso nome: `present`, e `link` se l'esistente non ha il file e la sorgente sì; (b) con nome ↔ esistente omesso, in ordine: `link`; (c) omesso ↔ esistente non ancora abbinato (omesso o con nome), in ordine: `present`; (d) il resto `insert`.
3. **Possibile doppione**: un non-media non abbinato è `insert(possibleDuplicate: true)` se nel gruppo c'è un esistente non abbinato dello stesso `kind` il cui testo coincide ignorando maiuscole e spazi ripetuti, oppure se differiscono solo per `edited`; altrimenti `insert(false)`.

Regola delle date: `analyze` carica dal database solo gli esistenti con `ts` tra il minimo e il massimo del file; se non ce ne sono, `overlaps == false` e tutto è `insert(false)`.

`apply`: un solo `db.write`. Crea conversazione/partecipanti/alias se servono, la riga `import_batch`, i messaggi `insert`, le righe `attachment` (Task 4). Prima di scrivere rilegge il numero di messaggi della conversazione e fallisce con `ImportError.archiveChanged` se è diverso da quello visto in `analyze`. `failureInjection` viene chiamata ogni 100 messaggi.

`undoLastImport`: un solo `db.write`. Cancella `attachment WHERE batch_id`, `message WHERE batch_id` (le stelle seguono per cascata), alias e partecipanti con `created_by_batch`, poi la conversazione se `created_conversation`, altrimenti `status = 'undone'`. Vale solo per l'importazione `applied` più recente della conversazione.

- [ ] **Step 1:** `Fixtures.swift`: `makeChat(count:start:senders:step:) -> String` che genera righe nel formato reale, e `tempDir()` con pulizia in `tearDown`.
- [ ] **Step 2:** `MergeTests` (falliscono): ripetizioni identiche (3 esistenti, 3 in arrivo → 3 `present`; 3 esistenti, 4 in arrivo → 3 `present` + 1 `insert(false)`); stesso testo, secondo diverso → `insert(false)`; omesso esistente + con nome in arrivo → `link`; due con nome diversi nello stesso secondo → secondo `insert`; testo che differisce solo per maiuscole → `insert(true)`; mittente diverso → `insert(false)`.
- [ ] **Step 3:** `ImportScenarioTests` (falliscono), con i numeri della specifica:
  - `test1_thousand`: 1.000 → `count == 1000`, summary `newMessages == 1000`.
  - `test2_overlap`: secondo file = messaggi 501…1000 + 300 nuovi → summary `alreadyPresent == 500`, `newMessages == 300`; totale 1.300; i 1.000 id originali esistono ancora con testo identico.
  - `test3_sameFileTwice`: `newMessages == 0`, totale invariato.
  - `test6_sameTextDifferentTime`: entrambi presenti.
  - `test7_interrupted`: `failureInjection` lancia al passo 3 → `apply` lancia; conteggi di tutte le tabelle e `PRAGMA integrity_check` identici a prima; nessuna riga `import_batch` nuova.
  - `test8_realRepeats`: file con 3 righe identiche nello stesso secondo → 3; reimportato → 3.
  - `test9_aliases`: primo file con `demox18`/`Hamburger`, secondo con `demy`/`sorrysora` e 200 messaggi in comune, mappati con `.existing` → `alreadyPresent == 200`, due partecipanti, quattro alias.
  - `test10_undo`: dump ordinato di tutte le tabelle prima della seconda importazione == dump dopo `undoLastImport`; con una stella su un messaggio della seconda importazione `canUndo` riporta `starsLost == 1`; un secondo `undo` agisce sulla prima importazione e rimuove la conversazione.
  - `test11_noOverlap`: file successivo di un anno → `overlaps == false`, ordine cronologico per `(ts, batch_id, seq)`.
  - `testSuggestMatchesByAlias`, `testArchiveChangedBetweenAnalyzeAndApply`.
- [ ] **Step 4:** implementare; `swift test` verde. Commit.

---

### Task 4: Media e ZIP

**Files:** `Media/MediaStore.swift`, `Media/OggOpusToCAF.swift`, `Media/Thumbnailer.swift`, `Importing/ImportSource.swift` (aggiunta `ZipSource`), modifica di `Importer.apply`, `MediaImportTests.swift`, `OggTests.swift`

**Interfaces — Produces:**

```swift
public final class MediaStore: Sendable {
    public let root: URL                                          // …/media
    public func url(forHash: String, ext: String) -> URL          // media/ab/abcdef….ext
    public func ingest(fileAt: URL, ext: String) throws -> (hash: String, size: Int64, existed: Bool)
    public func removeOrphans(referenced: Set<String>) throws -> Int
}
public struct ZipSource: ImportSource { public init(url: URL) throws }   // chat = prima voce *.txt (preferendo _chat.txt)
public enum OggOpusToCAF { public static func convert(_ input: URL, to output: URL) throws }
public enum Thumbnailer { public static func thumbnail(for: URL, kind: MessageKind, maxPixel: Int) -> CGImage? }
```

Decisioni:
- `ZipSource` usa `Archive(url:accessMode:.read)`; `attachmentNames` = ultimo componente di ogni voce non-TXT e non cartella; una voce il cui percorso contiene `..` viene ignorata; a nomi ripetuti vince la prima.
- `apply`: per ogni allegato da collegare, estrae in `media/.staging/<uuid>`, calcola SHA-256 in streaming, `ingest` (sposta, o scarta se l'impronta esiste già). Tiene l'elenco dei file **nuovi** creati; se la transazione fallisce li cancella. La cartella `.staging` viene svuotata a ogni avvio dello store, insieme a `removeOrphans`.
- Audio `.opus`: dopo `ingest`, `OggOpusToCAF.convert` in `media/…/<hash>.caf`; `attachment.playable_hash` = hash dell'originale se la conversione riesce, altrimenti `NULL`.
- `OggOpusToCAF`: legge le pagine Ogg (`OggS`, tabella dei segmenti, pacchetti che attraversano le pagine), prende `OpusHead` (canali, pre-skip) e salta `OpusTags`; scrive CAF con `desc` (48.000 Hz, `'opus'`, 960 frame per pacchetto, canali), `pakt` con dimensioni a lunghezza variabile e `mPrimingFrames = pre-skip`, `data`. La durata di ogni pacchetto si ricava dal byte TOC; se i pacchetti non sono tutti da 20 ms si scrive `mFramesPerPacket = 0` con le durate nella tabella.
- Spazio libero: `apply` lancia `ImportError.notEnoughSpace` se `volumeAvailableCapacityForImportantUsage` è minore della somma delle dimensioni non compresse + 200 MB.
- `ImportSummary`: `photos…documents` contano i file presenti nella sorgente e citati dalla chat; `missingAttachments` i nomi citati senza file né nella sorgente né nell'archivio.

- [ ] **Step 1:** `Fixtures`: `makeZip(chat:files:) -> URL` (crea lo ZIP con ZIPFoundation), JPEG/PNG 2×2 generati con ImageIO, byte arbitrari per webp/mp4.
- [ ] **Step 2:** test che falliscono in `MediaImportTests`:
  - `test4_mediaImport`: ZIP con 3 foto, 2 video, 4 sticker → 9 righe `attachment`, ogni file esiste su disco con l'impronta giusta, summary `photos == 3, videos == 2, stickers == 4, missingAttachments == 0`.
  - `test5_textThenMedia_omitted`: TXT con `immagine omessa` ×3, poi ZIP con gli stessi istanti e `<allegato: …>` → messaggi invariati di numero, 3 allegati collegati agli **id originali**, summary `attachmentsToLink == 3, newMessages == 0`.
  - `test5b_namedButMissingThenZip`: TXT con `<allegato: X.jpg>` (file assente → `missingAttachments == 1`), poi ZIP → collegato, nessun messaggio nuovo.
  - `testSameFileDeduplicatedOnDisk`: stesso contenuto con due nomi → un solo file su disco, due righe `attachment`.
  - `testZipEntryNames` (Review Focus 2): voci `a/b/foto.jpg`, `../../evil.jpg`, due `foto.jpg` → nessun file fuori da `media/`, `evil.jpg` ignorato.
  - `testFailureDuringCopyLeavesNothing` (Review Focus 4): estrazione che lancia al terzo file → tabelle identiche a prima, `media/` senza file nuovi, `.staging` vuota.
  - `testUndoUnlinksAttachments` (Review Focus 5): dopo `test5`, `undo` → i 3 messaggi tornano senza allegato, file rimossi da `removeOrphans`, messaggi originali intatti.
  - `testManyEntriesStreaming` (Review Focus 1): ZIP con 3.000 voci da 1 KB → importato, `progress` chiamata con valori crescenti fino a 1.0.
  - `OggTests.testPageParsing`: tre pagine Ogg costruite a mano (OpusHead, OpusTags, due pacchetti di cui uno a cavallo di pagina) → CAF che `AudioFileOpenURL` apre e che riporta 2 pacchetti.
- [ ] **Step 3:** implementare; `swift test` verde.
- [ ] **Step 4:** verifica locale non automatica: convertire un vocale vero dell'utente e aprirlo con `AVAudioFile` (deve dare una durata > 0). Se fallisce, correggere prima di proseguire. Commit.

---

### Task 5: Letture per l'interfaccia

**Files:** `Database/Queries.swift`, `QueryTests.swift`

**Interfaces — Produces** (estensione di `ArchiveStore`):

```swift
public struct ChatSummary: Identifiable { id, title, avatarHash, lastText, lastKind, lastTS, messageCount, starredCount }
public struct MessageRow: Identifiable, Equatable { id, ts, kind, text, senderName, isMe, edited, possibleDuplicate, starred,
                                                    attachment: AttachmentInfo? /* fileName, sha256, ext, playableHash */, mediaMissing: Bool }
public struct SearchFilter { var text: String?; var participantID: Int64?; var day: Int64? /* inizio giornata */; var starredOnly: Bool; var conversationID: Int64? }
public enum MediaSection { case media, stickers, audio, documents, links }

func chatList() throws -> [ChatSummary]                                   // ordinato per lastTS decrescente
func messages(conversationID:, around anchor: Int64?, limit: Int) throws -> [MessageRow]   // anchor nil = ultimi
func messages(conversationID:, before: MessageRow, limit: Int) throws -> [MessageRow]
func messages(conversationID:, after: MessageRow, limit: Int) throws -> [MessageRow]
func search(_ filter: SearchFilter, limit: Int) throws -> [SearchHit]     // SearchHit: MessageRow + conversationID + titolo
func setStar(messageID: Int64, _ on: Bool) throws
func starred() throws -> [SearchHit]
func mediaItems(conversationID:, section: MediaSection) throws -> [MessageRow]
func conversationInfo(id:) throws -> ConversationInfo   // titolo, conteggio, primo e ultimo ts, partecipanti con alias, importazioni
func rename(conversationID:, to:), setMe(participantID:), deleteConversation(id:)   // deleteConversation solo su richiesta esplicita dell'utente
```

Decisioni: ricerca testuale con FTS5, ogni parola tra virgolette e con prefisso `*` sull'ultima; `links` = messaggi `text` con `http://` o `https://`; `mediaMissing` = kind media senza riga `attachment`.

- [ ] **Step 1:** test che falliscono: paginazione avanti/indietro senza buchi né ripetizioni su 1.000 messaggi con più messaggi nello stesso secondo; `around` centra il messaggio; ricerca per parola, per frase, con accento (`perche` trova `perché`), per mittente, per giorno, solo stelle; virgolette e `*` nel testo cercato non fanno fallire la query; stella messa e tolta; `chatList` con ultimo messaggio e `starredCount`; sezioni media.
- [ ] **Step 2:** implementare; `swift test` verde. Commit.

---

### Task 6: Progetto Xcode, elenco chat, importazione

**Files:** `App/ArchivioChat.xcodeproj/project.pbxproj` (scritto a mano, gruppi sincronizzati con la cartella, pacchetto locale `../ArchivioCore`), `ArchivioChatApp.swift`, `AppModel.swift`, `Theme.swift`, `Chats/*`, `Import/*`

Decisioni:
- Bundle id `local.demox.ArchivioChat`, nome mostrato "Archivio Chat", iOS 17.0, solo iPhone, solo verticale. Nessuna chiave di rete in Info.plist. `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace` a NO.
- `AppModel` (`@Observable`, `@MainActor`): possiede `ArchiveStore` in `Application Support/Archivio`, espone `chats`, `reload()`. Argomento di lancio `-archivioDir <percorso>` per puntare a un'altra cartella (serve alla verifica nel simulatore).
- `Theme`: verde fumetto inviato `#D9FDD3` (chiaro) / `#005C4B` (scuro); ricevuto bianco / `#202C33`; sfondo chat `#EFEAE2` / `#0B141A`; accento `#00A884`.
- Importazione: `fileImporter` con tipi `.zip` e `.plainText`, selezione multipla; i file si elaborano **uno alla volta** in sequenza. Per ciascuno: accesso security-scoped → `suggest` → schermata destinazione (nuova chat con titolo e "chi sei tu", oppure chat esistente con abbinamento dei nomi, precompilato quando gli alias coincidono) → `analyze` → `PreviewView` con i numeri di `ImportSummary` → Conferma → `apply` con barra di avanzamento → esito. Analisi e applicazione fuori dal thread principale. Ogni errore diventa un avviso con testo chiaro e nulla viene scritto.
- `ChatRow`: avatar (immagine o iniziali su colore derivato dal nome), titolo, anteprima dell'ultimo messaggio con icona per i media, data (ora se oggi, "Ieri", altrimenti data breve), stellina se `starredCount > 0`.

- [ ] **Step 1:** scrivere il progetto; `xcodebuild -project App/ArchivioChat.xcodeproj -scheme ArchivioChat -destination 'platform=iOS Simulator,name=iPhone 18 Pro' build` → `BUILD SUCCEEDED`.
- [ ] **Step 2:** implementare elenco e flusso d'importazione; build verde.
- [ ] **Step 3:** nel simulatore: importare un TXT inventato da 1.000 messaggi e uno ZIP inventato con media; l'elenco mostra le chat; reimportare lo stesso file mostra nell'anteprima 0 nuovi. Screenshot. Commit.

---

### Task 7: Conversazione

**Files:** `Conversation/*`

Decisioni:
- `ConversationViewModel`: finestra di messaggi in memoria (blocchi da 200, massimo 800: quando si supera, si scarta dal lato opposto), `loadEarlier()`, `loadLater()`, `jump(to messageID:)` che ricarica attorno al messaggio e lo evidenzia per 1,5 secondi.
- Lista: `ScrollView` + `LazyVStack` con `scrollPosition(id:)`, ancorata in basso all'apertura. Separatore di giornata quando cambia il giorno ("Oggi", "Ieri", altrimenti `d MMMM yyyy`).
- `BubbleView`: coda a destra/sinistra secondo `isMe`; nome del mittente solo se i partecipanti sono più di due; orario `HH:mm`; stellina e "modificato" accanto all'orario; `call`, `system`, `deleted` come capsule grigie centrate (deleted in corsivo dentro un fumetto, come WhatsApp).
- Media: foto e GIF con miniatura a larghezza massima 260 pt; video con miniatura e simbolo di riproduzione; sticker 140 pt senza fumetto (WebP animati con ImageIO, fermi se "Riduci movimento" è attivo); audio con play/pausa, barra e durata (`AVAudioPlayer` sul file `.caf`); documento con icona e nome; media mancante con riquadro tratteggiato "Foto non disponibile" (e simili).
- Tocco: mostra data e ora complete sotto il fumetto. Pressione prolungata: `contextMenu` con "Aggiungi ai preferiti"/"Rimuovi dai preferiti", "Copia", "Info".
- Intestazione: avatar + titolo, toccabile → Info. Lente → ricerca nella chat. Nessuna barra di scrittura.
- Miniature: cache in memoria (`NSCache`) + su disco in `Caches/thumbs/<hash>.jpg`, generate fuori dal thread principale.

- [ ] **Step 1:** implementare; build verde.
- [ ] **Step 2:** nel simulatore, sulla chat inventata: fumetti ai due lati, separatori, media, stella messa e tolta (persistente dopo riavvio), scorrimento all'indietro fino al primo messaggio senza salti. Screenshot chiaro e scuro. Commit.

---

### Task 8: Info, raccolta, ricerca, preferiti, impostazioni

**Files:** `Info/*`, `Search/*`, `Starred/*`, `Settings/*`

Decisioni:
- `ConversationInfoView`: avatar grande (sostituibile con `PhotosPicker`, copiato in `media/`), titolo modificabile, numero di messaggi, primo e ultimo messaggio, partecipanti con i loro alias e scelta "sono io", riga "Media, link e documenti" con conteggio, riga "Messaggi importanti", elenco delle importazioni (file, data, messaggi aggiunti) con "Annulla ultima importazione" — conferma con avviso che indica quante stelle andrebbero perse — ed "Elimina conversazione" con doppia conferma.
- `MediaGalleryView`: selettore Media / Sticker / Audio / Documenti / Link; griglia a 3 colonne (4 per gli sticker) raggruppata per mese, caricata a pagine.
- `MediaViewer`: `fullScreenCover`, pagine scorrevoli, zoom con pizzico e doppio tocco, video con `VideoPlayer`, data e mittente in alto, "Mostra nella chat" che esegue `jump(to:)`.
- `SearchView`: campo di testo; filtri mittente (menu), giorno (`DatePicker`), solo preferiti; globale dalla scheda Chat, limitata alla chat dalla conversazione; risultati con la parola evidenziata; tocco → conversazione su quel messaggio.
- `StarredView`: scheda Preferiti, raggruppati per chat, tocco → messaggio.
- `SettingsView`: spazio occupato (database + media), numero di chat/messaggi/allegati, "Svuota cache miniature", nota "Tutti i dati restano su questo iPhone".

- [ ] **Step 1:** implementare; build verde.
- [ ] **Step 2:** nel simulatore: raccolta, visualizzatore, ricerca con salto al messaggio, preferiti, annullamento dell'ultima importazione con ritorno dell'elenco allo stato precedente. Screenshot. Commit.

---

### Task 9: Verifica con i file veri e consegna

- [ ] **Step 1:** copiare i due ZIP veri nel simulatore (`xcrun simctl` nella cartella File dell'app File) e importarli dall'app come farebbe l'utente: prima `Hamburger<3🥰`, poi `sorrysora` nella stessa conversazione abbinando i nomi. Atteso: 50.476 poi +52.578 messaggi = 103.054; 2.958 + 6.960 allegati; `missingAttachments` coerente con i media omessi. Reimportare il secondo: 0 nuovi.
- [ ] **Step 2:** misurare tempo di importazione e fluidità dello scorrimento; un vocale si riproduce; uno sticker animato si vede; ricerca sotto il secondo.
- [ ] **Step 3:** `swift test` completo verde; cancellare i dati di prova dal simulatore e le estrazioni temporanee.
- [ ] **Step 4:** scrivere `README.md` con i passi per installare sull'iPhone (cavo, Apple ID in Xcode, Modalità sviluppatore, scadenza a 7 giorni). Aggiornare le note Obsidian. Commit.
