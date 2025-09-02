# Photoscenery‑GUI (Julia)

> **GUI web moderna** per scaricare e assemblare ortofoto (photoscenery) da map server esterni e usarle in **FlightGear**. La nuova versione aggiunge un’interfaccia interattiva, download parallelo dei chunk, monitor dell’assemblaggio e conversione **PNG↔DDS** interamente in Julia.

---

## Caratteristiche principali
- **GUI Web**: mappa interattiva (selezione da ICAO/città o click su mappa), raggio in NM, risoluzione **0–6**, riduzione con la distanza (**--sdwn**) con opzione *pre‑coverage*, anteprima tile, filtro per data, gestione coda, opacità overlay, e stato connessione **FGFS**.
- **Compatibilità batch/CLI**: la GUI accetta le stesse opzioni della versione console.
- **Download multi‑thread** dei chunk e **assemblaggio automatico** in tile completi.
- **Gestione DDS**: import di DDS esistenti senza riscaricarli; conversioni **png2ddsDXT1**/**dds2pngDXT1** ad alte prestazioni (niente più dipendenza da ImageMagick).
- **Integrazione FlightGear**: download attorno all’aeromobile in volo via telnet FGFS; percorso di output pronto per essere usato come sorgente Scenery.
- **Prestazioni**: scanning più rapido delle directory e verifica dei chunk per evitare artefatti/neri.

---

## Requisiti
- **Julia** ≥ 1.11.x (ambiente di progetto fornito)
- Sistema: Linux, Windows, macOS

Pacchetti Julia (principali): `ArgParse`, `HTTP`, `JSON3`, `LightXML`, `Downloads`, `Images`/`ImageIO`/`FileIO`/`PNGFiles`, `Dates`, `Logging`, `FilePathsBase`, `Colors`, `Printf`.

---

## Installazione
```bash
# Clona o scarica il repository
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

---

## Avvio rapido (GUI)
```bash
# dalla cartella del progetto
julia --project=. -e 'using Photoscenary; Photoscenary.GuiMode.run(["--http=8000"])'
# poi apri: http://127.0.0.1:8000/
```
**Consigli**: usa Firefox (rendering mappa più rapido). Imposta `--path` verso la cartella Scenery di FlightGear (o lascia l’automatico).

---

## Flusso di lavoro (GUI)
1. **Località**: inserisci **ICAO** (es. `LIME`) o clicca il bottone mirino e **seleziona a mappa**.
2. **Raggio e Risoluzione**: imposta **Radius (nm)** e **Resolution (0–6)**. 
3. **Riduzione con distanza**: seleziona il livello **--sdwn** (0→senza down‑sampling; 1–4 anteprime più leggere) e, se serve, *Pre‑coverage* per copertura di avvicinamento prima dell’alta risoluzione.
4. **Overwrite**: scegli **--over** `0` (mai), `1` (solo se risoluzione migliore), `2` (sempre).
5. **Avvia**: crea l’area (cerchio arancione), poi **Conferma (✓)** per metterla in coda. Il server scarica i chunk in `.../tmp/` e assemblea i tile finali.
6. **FlightGear** (opzionale): imposta porta telnet (es. `5000`) e **connetti** per seguire l’aereo e scaricare *attorno all’aeromobile*.

---

## Opzioni principali (CLI)
| Opzione | Descrizione |
| --- | --- |
| `--size s` | Risoluzione massima: `0→512`, `1→1024`, `2→2048`, `3→4096`, `4→8192`, `5→16384`, `6→32768` px (lato lungo). |
| `--radius r` | Raggio in **NM** attorno al centro. |
| `--over n` | Sovrascrittura: `0` mai, `1` solo se migliore, `2` sempre. |
| `--sdwn n` | Riduzione con la distanza (down‑sampling progressivo). |
| `--map n` | ID del map server. |
| `--icao CODE` | Risolve **LAT/LON** da codice aeroportuale. |
| `--route file.xml` | Importa una rotta/waypoint e scarica lungo il percorso. |
| `--connect host:port` | Connetti a **FGFS** (telnet) per seguire l’aereo. |
| `--path PATH` | Directory di output (Scenery).  |
| `--save PATH` | Copia/archivia i file rimossi. |
| `--png` | Salva in PNG (per debug/analisi); altrimenti DDS. |
| `--lat --lon` | Centro area in gradi decimali (oppure `-x` per sessagesimale). |
| `--latll --lonll --latur --lonur` | Bounding box esplicita. |
| `--tile n` | Lavoro su tile indicizzato. |
| `--attemps n` | Tentativi di download per chunk. |
| `--timeout s` | Timeout download per chunk. |
| `--logger n` | Log: `0` console, `1` file+console, `2` solo file. |
| `--debug n` | Livello debug. |
| `--http[=port]` | Avvia il web server locale (default 8000 se flag senza valore). |

> Per l’elenco completo e spiegazioni operative, vedi la wiki del progetto.

---

## Architettura & Moduli
- **Photoscenary** *(root)*: bootstrap, logging, parsing CLI (via `AppConfig`), avvio modalità `GuiMode`/`BatchMode`.
- **AppConfig**: inizializza/legge `params.xml`, parsing opzioni/ preset.
- **Commons**: tipi e utilità condivise (es. `MapCoordinates`, `ChunkJob`, mapping risoluzioni, `adaptive_size_id`).
- **GeoEngine**: orchestration end‑to‑end: calcolo tile per area, creazione job (pre‑coverage e alta risoluzione), gestione percorsi.
- **Downloader**: coda lavori (priorità *high/low*), download parallelo chunk, validazioni, gestione fallback.
- **AssemblyMonitor**: scansione `tmp/`, rilevamento gruppi completi, trigger assemblaggio.
- **TileProcessor**: mosaicatura chunk → immagine, conversione **PNG→DDS DXT1** e posizionamento file finali.
- **GuiMode**: server HTTP locale + API REST (`/api/start-job`, `/api/connect`, `/api/resolve-icao`, …), stato sessione/coda, anteprime **DDS→PNG** e interazione con la pagina web.
- **png2ddsDXT1 / dds2pngDXT1**: codec ad alte prestazioni in pura Julia.

**Pipeline semplificata**: Area → lista tile → suddivisione in chunk → download parallelo → monitor → assemblaggio → (conversione) → deposito nella cartella Scenery.

---

## Integrazione con FlightGear
1. Avvia FG con telnet (esempio): `--telnet=5000`.
2. In GUI, inserisci la porta e **connetti**.
3. Imposta `--path` verso `Downloads/TerraSync/Orthophotos` (o equivalente). 
4. In FlightGear 2020.3.x abilita **Satellite Photoscenery** dalle opzioni di rendering.

---

## Consigli pratici
- **Strategia sdwn+pre‑coverage**: copri ampie aree a bassa risoluzione per il contesto e scarica in alta vicino alla rotta/destinazione.
- **Overwrite 1** è un buon default: migliora senza rifare tutto.
- **Connessione**: per aree vaste, preferisci una rete stabile ad alta banda.
- **Performance**: imposta thread Julia in base ai core disponibili (`julia -t auto`).

---

## Struttura directory (output)
```
photosceneryOrthophotos-saved/
  tmp/           # chunk .png in attesa di assemblaggio
  e000n00/ ...  # tile finali .dds (o .png se richiesto)
```

---

## Roadmap (breve)
- Migliorie input **ICAO** e selezione multi‑cerchio/rotta.
- Parità completa con tutte le opzioni batch.
- Rifiniture UI e stati interni.

---

## Licenza
GPL‑2.0. Vedi file `LICENSE` nel repository.

---

## Crediti
- Progetto originario e documentazione community su FlightGear Wiki.
- Contributors e tester della community FlightGear.
