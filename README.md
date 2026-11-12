# Archivio Chat

App per iPhone, a uso personale, che importa le chat esportate da WhatsApp (TXT e ZIP con allegati), le unisce senza perdere nulla e le fa consultare con un'interfaccia simile a WhatsApp.

Non è un'app di messaggistica: non invia, non riceve, non si collega a WhatsApp e non usa la rete. Tutti i dati restano sull'iPhone.

## Com'è fatta

```
ArchivioCore/   pacchetto Swift senza interfaccia: parser, database, fusione, media
  Sources/ArchivioCore/
    Parsing/     testo dell'esportazione → messaggi tipizzati
    Database/    schema SQLite (GRDB), letture per l'interfaccia
    Importing/   analisi, anteprima, applicazione in transazione, annullamento
    Media/       file per impronta SHA-256, miniature, conversione dei vocali
  Tests/         test automatici
App/            app SwiftUI che usa ArchivioCore
docs/           specifica di design e piano di implementazione
```

## Eseguire i test

```bash
cd ArchivioCore && swift test
```

I test usano solo dati inventati. Tre verifiche aggiuntive girano solo se si indica un file vero con una variabile d'ambiente (`ARCHIVIO_REAL_TXT`, `ARCHIVIO_REAL_OPUS_DIR`, `ARCHIVIO_REAL_ZIPS`) e stampano soltanto numeri.

## Installare sull'iPhone

Serve un cavo, Xcode e il tuo Apple ID (va bene quello normale, senza abbonamento da sviluppatore).

1. Apri `App/ArchivioChat.xcodeproj` con Xcode.
2. In Xcode: **Settings → Accounts → +** e accedi con il tuo Apple ID.
3. Nel pannello di sinistra seleziona il progetto **ArchivioChat**, poi il target **ArchivioChat**, scheda **Signing & Capabilities**: spunta *Automatically manage signing* e scegli il tuo nome in **Team**. Se Xcode segnala che l'identificativo è già in uso, cambia `local.demox.ArchivioChat` aggiungendo qualcosa in fondo.
4. Sull'iPhone: **Impostazioni → Privacy e sicurezza → Modalità sviluppatore**, attivala e riavvia quando richiesto.
5. Collega l'iPhone al Mac con il cavo e, sull'iPhone, tocca *Autorizza questo computer*.
6. In alto in Xcode scegli il tuo iPhone come destinazione e premi **▶**.
7. Al primo avvio l'iPhone rifiuta l'app: vai in **Impostazioni → Generali → VPN e gestione dispositivi**, tocca il tuo Apple ID e scegli *Autorizza*. Poi riapri l'app.

Con un Apple ID normale l'app scade dopo 7 giorni: basta ricollegare l'iPhone e premere di nuovo **▶**. I dati importati restano, a patto di non disinstallare l'app.

## Importare una chat

1. In WhatsApp: apri la chat → nome del contatto → **Esporta chat** → *Allega media* (oppure senza) → **Salva su File**.
2. In Archivio Chat: **+** in alto a destra, scegli lo ZIP o il TXT.
3. Scegli se creare una chat nuova o unire a una esistente, e indica chi sei tu.
4. Controlla l'anteprima e conferma.

L'ultima importazione di ogni chat si può annullare da **Info chat → Importazioni**.
