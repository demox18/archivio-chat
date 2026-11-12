# Archivio Chat — specifica di design

Data: 12 novembre 2026

## 1. Scopo

App per iPhone, a uso personale e mai pubblicata, che importa le chat esportate da WhatsApp (TXT e ZIP con allegati), le unisce in conversazioni e le fa consultare con un'interfaccia simile a WhatsApp.

Non è un'app di messaggistica: non invia, non riceve, non chiama, non si collega a WhatsApp e non usa la rete.

**Priorità assoluta: nessun messaggio, allegato o conversazione già importata deve andare perso per colpa di una nuova importazione.** Nel dubbio si conserva un doppione.

## 2. Vincoli

- Swift e SwiftUI, iOS 17 o successivo, solo iPhone.
- Funziona senza internet. L'app non contiene codice di rete.
- I file scelti dall'utente non vengono mai modificati: si leggono e si copiano.
- Formato supportato ora: esportazione da iPhone, in italiano e in inglese. Android non è incluso, ma il parser è fatto a "dialetti" per aggiungerlo dopo.
- Librerie esterne: GRDB (SQLite) e ZIPFoundation (lettura ZIP), scaricate solo in compilazione.

## 3. Formato reale osservato

Dalle due esportazioni vere dell'utente (iPhone, italiano):

- Riga di messaggio: `[gg/mm/aa, hh:mm:ss] Mittente: testo`, fine riga CRLF, senza BOM. Davanti alla parentesi può esserci il carattere invisibile U+200E.
- Le righe che non iniziano con questa intestazione continuano il messaggio precedente.
- Il testo può essere vuoto (`[..] Mittente:` e poi a capo).
- Allegato: `<allegato: 00000012-PHOTO-2025-08-22-13-44-43.jpg>` (in inglese `<attached: …>`). Tipi nel nome: `PHOTO`, `VIDEO`, `GIF`, `STICKER`, `AUDIO`; altri nomi sono documenti.
- Media non incluso, senza nome file: `immagine omessa`, `video omesso`, `audio omesso`, `sticker non incluso`, `GIF esclusa`, `documento omesso` (e gli equivalenti inglesi).
- Righe di servizio, precedute da U+200E: chiamate e videochiamate, messaggi eliminati, messaggio fissato, blocco e sblocco, avviso di crittografia.
- Suffisso `<Questo messaggio è stato modificato>` in fondo al testo.
- Lo stesso file contiene ripetizioni vere: stesso secondo, stesso mittente, stesso testo (84 in un file, 9 nell'altro).
- La stessa persona compare con nomi diversi in esportazioni diverse, **compreso l'utente** (`demox18` in una, `demy` nell'altra).

## 4. Architettura

Cartella `~/claude/archivio-chat`.

```
ArchivioCore/            pacchetto Swift, senza interfaccia, con i test
  Parsing/               testo → messaggi tipizzati
  Database/              schema, migrazioni, letture
  Importing/             analisi, anteprima, fusione, annullamento
  Media/                 archivio dei file, miniature, conversione audio
App/                     app SwiftUI che usa ArchivioCore
```

Le dipendenze vanno in una sola direzione: `App → Importing → (Parsing, Database, Media)`. Parsing non conosce il database. L'interfaccia non scrive mai SQL.

### 4.1 Parsing

`ChatParser.parse(testo) → [ParsedMessage]`

`ParsedMessage`: data e ora (componenti locali, senza fuso orario, come nel file), nome del mittente come scritto, `kind`, testo, nome dell'allegato se c'è, flag `modificato`, numero di riga d'origine.

`kind`: `text`, `photo`, `video`, `gif`, `sticker`, `audio`, `document`, `call`, `deleted`, `system`. Un media può avere o non avere nome file (omesso).

Una riga che il parser non sa interpretare non viene mai scartata: diventa continuazione del messaggio precedente oppure, se è la prima, un messaggio `system` con il testo grezzo. Il parser riporta anche il numero di righe non riconosciute, da mostrare nell'anteprima.

### 4.2 Database

SQLite tramite GRDB, in `Application Support/Archivio/archivio.sqlite`, modalità WAL, chiavi esterne attive.

| Tabella | Contenuto |
|---|---|
| `conversation` | id, titolo, immagine facoltativa, data di creazione |
| `participant` | id, conversazione, nome mostrato, `is_me` |
| `participant_alias` | partecipante, nome come scritto nei file (unico per conversazione) |
| `import_batch` | id, conversazione, nome del file, impronta SHA-256 del file, data, stato (`applied`, `undone`), conteggi |
| `message` | id, conversazione, partecipante, istante, `kind`, testo, nome allegato, `occurrence`, `edited`, `possible_duplicate`, importazione d'origine, riga d'origine |
| `attachment` | id, messaggio, nome file, SHA-256, dimensione, tipo, importazione che lo ha portato |
| `star` | messaggio, data |
| `message_fts` | indice FTS5 sul testo, tenuto allineato da trigger |

Indici: `message(conversation, istante, id)` per lo scorrimento, `message(conversation, istante, partecipante)` per la fusione.

Le stelle stanno in una tabella a parte e non toccano mai i messaggi.

### 4.3 Fusione

Due fasi, sempre.

**Fase 1 — analisi (non scrive nulla).** Si legge il file, si calcola la sua impronta, si fa il parsing e si costruisce un `ImportPlan` con l'anteprima.

**Fase 2 — applicazione.** Solo dopo la conferma dell'utente, in **una sola transazione**: o entra tutto o non entra niente. Prima si copiano i file multimediali nell'archivio (operazione che da sola non altera nulla di visibile), poi si scrive il database. Se qualcosa fallisce, la transazione torna indietro e i file copiati rimasti senza riferimenti vengono rimossi.

**A quale conversazione appartiene il file.** L'app propone, l'utente conferma:

1. Se un nome di mittente del file è già un alias di una conversazione, propone quella.
2. Altrimenti l'utente sceglie "nuova conversazione" oppure una esistente.
3. Unendo a una conversazione esistente, l'utente abbina i nomi nuovi ai partecipanti (`demy` = `demox18`). I nuovi nomi diventano alias.

**Regola delle date (indicata dall'utente).** Il punto di aggancio tra due esportazioni è il tempo: dove gli intervalli di date si sovrappongono si confrontano i messaggi; dove non c'è sovrapposizione il file viene semplicemente aggiunto, in ordine cronologico, senza confronti.

**Quando due messaggi sono lo stesso.** Chiave: istante al secondo, partecipante (dopo gli alias), `kind`, testo normalizzato (senza U+200E, senza spazi in coda, a capo uniformati), nome dell'allegato.

Poiché esistono ripetizioni vere, la chiave ha anche `occurrence`: la prima, la seconda, la terza volta che quella chiave compare nel file. Un messaggio del file è "già presente" solo se nell'archivio esiste la stessa chiave con la stessa occorrenza. Così:

- importare due volte lo stesso file non duplica nulla;
- tre sticker identici nello stesso secondo restano tre.

**Segnaposto completati.** Se nell'archivio c'è un media omesso e il file porta, per lo stesso istante, partecipante e tipo, un messaggio con allegato (o viceversa), sono lo stesso messaggio: non se ne crea uno nuovo e l'allegato viene collegato a quello esistente. Con più candidati nello stesso secondo si abbinano in ordine; quelli in eccesso si aggiungono.

**Possibili doppioni.** Stesso istante e partecipante, testo uguale salvo differenze minori (marcatore di modifica, spazi) ma non coincidente in modo certo: il messaggio viene **aggiunto** e segnato `possible_duplicate`. Non si elimina mai nulla per somiglianza.

**Cosa la fusione non fa mai.** Non cancella righe. Non modifica testo, data o mittente di un messaggio esistente. L'unica scrittura su dati esistenti è collegare un allegato a un messaggio che non lo aveva.

**Anteprima.** Messaggi già presenti, nuovi, possibili doppioni, foto, video, sticker, audio e documenti trovati, allegati citati ma mancanti, righe non riconosciute, nomi di mittente non abbinati. Pulsanti: Conferma, Annulla.

**Annullare l'ultima importazione.** Disponibile per la più recente importazione `applied` di ogni conversazione. In una transazione: toglie i messaggi nati da quella importazione, scollega gli allegati che quella importazione ha collegato a messaggi più vecchi, toglie gli alias e i partecipanti che ha creato, segna l'importazione `undone`. Poi rimuove dal disco i file rimasti senza riferimenti. Le stelle messe su messaggi rimossi vengono rimosse con loro; l'utente viene avvisato prima se ce ne sono. Se la conversazione era stata creata da quella importazione, viene rimossa.

### 4.4 Media

- File in `Application Support/Archivio/media/`, nominati con la loro impronta SHA-256: lo stesso file importato più volte occupa spazio una sola volta.
- Lo ZIP si legge voce per voce in streaming, senza caricarlo in memoria (le esportazioni reali arrivano a 750 MB e 7.000 file).
- Miniature generate alla prima visualizzazione e tenute in `Caches/`, ricostruibili.
- Sticker WebP, anche animati, mostrati con ImageIO.
- Messaggi vocali `.opus` (Ogg Opus, non riproducibile da iOS): all'importazione si crea una copia in contenitore CAF, senza ricodifica. L'originale resta conservato. Se la conversione fallisce, il messaggio mostra "audio non riproducibile" e il file resta in archivio.
- Allegato citato ma assente: riquadro grigio "Contenuto non disponibile", con il tipo.
- Prima di importare si controlla lo spazio libero; se non basta, l'importazione non parte.

### 4.5 Interfaccia

Tre schede: **Chat**, **Preferiti**, **Impostazioni**.

- **Chat**: elenco con immagine (o iniziali), nome, ultimo messaggio, data, stellina se la chat ha preferiti. Pulsante `+` per importare con il selettore di file, anche più file insieme. Campo di ricerca.
- **Conversazione**: fumetti a destra (miei) e a sinistra, orario in ogni fumetto, separatore di giornata, nome del mittente nelle chat con più di due partecipanti, righe grigie centrate per chiamate e messaggi di servizio, etichetta "modificato". Foto, video, GIF e sticker nel flusso; audio con riproduttore. Tocco sul fumetto: data e ora complete. Pressione prolungata: menu con "Aggiungi ai preferiti" / "Rimuovi dai preferiti", "Copia", "Info". Nessun campo per scrivere.
- **Caricamento a blocchi**: la conversazione carica una finestra di messaggi attorno alla posizione corrente e ne aggiunge altri scorrendo. Necessario con 100.000 messaggi.
- **Info conversazione** (tocco sull'intestazione): nome modificabile, immagine, numero di messaggi, primo e ultimo messaggio, partecipanti e alias, elenco delle importazioni con "Annulla ultima importazione", e **Media, link e documenti** con le sezioni Media (foto, video, GIF), Sticker, Audio, Documenti, Link.
- **Visualizzatore** a schermo intero con zoom e scorrimento tra i media; video con i controlli di sistema.
- **Ricerca**: per parola o frase (FTS5), con filtri mittente, giorno e solo preferiti; nella singola chat o in tutte. Toccando un risultato si apre la conversazione su quel messaggio, evidenziato per un momento.
- **Preferiti**: tutti i messaggi con stella, raggruppati per chat, ognuno porta al messaggio originale.
- Tema chiaro e scuro, colori vicini a WhatsApp (verde per i fumetti inviati), animazioni brevi, nessun testo in movimento continuo.

## 5. Errori

- File non leggibile o ZIP corrotto: messaggio chiaro, nulla viene scritto.
- ZIP senza file di chat: lo si dice; nulla viene scritto.
- Errore a metà dell'applicazione: la transazione torna indietro, i file copiati vengono ripuliti, l'archivio resta com'era.
- App chiusa durante l'importazione: all'avvio successivo SQLite annulla da solo la transazione incompiuta; una pulizia rimuove i file multimediali senza riferimenti.

## 6. Test

Automatici, su `ArchivioCore`, con dati inventati:

1. Importare 1.000 messaggi → 1.000.
2. Seconda esportazione con 500 già presenti e 300 nuovi → 1.300, nessuno dei primi perso.
3. Stesso file due volte → nessun nuovo messaggio.
4. Chat con foto, video e sticker → allegati presenti e collegati.
5. Prima senza allegati, poi con → allegati collegati ai messaggi esistenti, conteggio invariato.
6. Stesso testo in momenti diversi → entrambi conservati.
7. Importazione interrotta a metà → database integro e identico a prima.

Nati dai file veri:

8. Ripetizioni vere nello stesso secondo → tutte conservate, anche reimportando.
9. Nomi diversi per la stessa persona → fusione corretta tramite alias.
10. Annullamento dell'ultima importazione → archivio identico a prima di quella importazione.
11. File senza sovrapposizione di date → semplice aggiunta in ordine.
12. Parser: righe multiple, testo vuoto, U+200E, marcatore di modifica, righe di servizio.

Verifica finale sui due file veri dell'utente, nel simulatore: conteggi attesi 50.476 e 52.578 messaggi, 2.958 e 6.960 allegati.

## 7. Fuori ambito

Invio e ricezione di messaggi, chiamate, rete, sincronizzazione, backup su cloud, formato Android, iPad, pubblicazione sull'App Store.
