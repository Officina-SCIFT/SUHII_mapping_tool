# 🌡️ SUHII Mapping

> **Map urban heat islands anywhere in the world — using only free, open data.**

`🇮🇹 Versione italiana più sotto — Italian version below`

<p align="center">
  <img src="shiny/www/scift.jpg" height="200" alt="Officina SCIFT logo"/>
</p>

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

---

## What does it do?

This tool automatically produces **Surface Urban Heat Island Intensity (SUHII)** maps for any city — no satellite expertise required.

```
You type a city name  →  the tool does the rest  →  you get maps + report
```

It uses three free data sources — no accounts required except one free API key:

| Data | Source | Account? |
|:-----|:-------|:--------:|
| 🛰️ Thermal satellite imagery | Landsat C2 L2 via Microsoft Planetary Computer | ✅ No |
| 🗺️ Land use & urban areas | OpenStreetMap via Overpass API | ✅ No |
| ⛰️ Elevation | SRTM GL1 DEM via OpenTopography | ⚠️ Free key needed |

> **LST ≠ air temperature.**
> The tool measures **Land Surface Temperature**: how hot surfaces (asphalt, rooftops, soil) get as seen from space — not the air temperature you feel outside.

---

## What you get

For each city, the tool saves these files to `data/<city>/Output/`:

| File | What it shows |
|:-----|:-------------|
| `warm_<year>_LST_MEAN.tif` | Average surface temperature (°C) |
| `warm_<year>_thermal_anomaly.tif` | How much hotter urban is vs rural (°C) |
| `warm_<year>_SUHI.tif` | Heat island intensity index (0–1) |
| `warm_<year>_anomaly_classified.tif` | 6-class severity map |
| `warm_<year>_priority_map.tif` | Where to intervene first (0–1) |
| `warm_<year>_distance_green_areas.tif` | Distance from green areas (m) |
| `warm_<year>_anomaly_classified.geojson` | GIS vector export |
| `warm_<year>_priority_map.geojson` | GIS vector export |
| `warm_<year>_city_stats.csv` | Summary statistics |
| `<city>_warm_<year>_report.html` | ✨ Full interactive HTML report |

---

## Getting started

### What you need

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — that's it. No R, no Python, no packages to install manually.
- A free [OpenTopography API key](https://opentopography.org/developers) (takes 2 minutes to get).

---

### Step 1 — Download the project

```bash
git clone https://github.com/Officina-SCIFT/SUHII_mapping.git
cd SUHII_mapping
```

Or download the ZIP from GitHub and extract it.

---

### Step 2 — Get your free API key

1. Go to [opentopography.org/developers](https://opentopography.org/developers)
2. Register (free, takes 2 minutes)
3. Copy the API key from your profile

---

### Step 3 — Add the key to the project

```bash
cp config/credentials.yml.example config/credentials.yml
```

Open `config/credentials.yml` and replace the placeholder:

```yaml
opentopography:
  api_key: "paste-your-key-here"
```



---

### Step 4 — Build and launch

```bash
docker-compose up --build
```

> ⏳ **The first build takes 10–15 minutes** — this happens only once.
> Docker is downloading R, Quarto, and all required packages (~1 GB).
> You will see a long stream of installation messages: this is normal, not an error.
> **Do not close the terminal.**
>
> All subsequent starts take under 30 seconds.

When you see this line in the terminal, the app is ready:

```
suhii_app | [INFO] Starting listener on 0.0.0.0:3838
```

---

### Step 5 — Open the app

👉 **[http://localhost:3838/suhii](http://localhost:3838/suhii)**

---

### Step 6 — Run an analysis

1. Type a **city name** (use the name as it appears in OpenStreetMap)
   → For small towns, add the province: `Bologna, Emilia-Romagna`
2. Click **Run analysis**
3. Watch the progress log on the left sidebar

> ☕ **Go grab a coffee — this takes a few minutes.**
>
> A typical analysis runs in **5–20 minutes** depending on city size.
> This is not a page loading: the tool is downloading satellite imagery,
> processing it, and computing thermal maps from scratch.
> The progress log keeps you updated while it works.
> Large cities (e.g. Moscow) can take up to ~2 hours.

---

### Step 7 — Explore your results

| Tab | What's there |
|:----|:------------|
| **Maps** | Four interactive Leaflet maps |
| **Charts** | SUHII class distribution, urban vs rural LST |
| **Report** | Full illustrated HTML report |
| **Downloads** | Download buttons for every output file |

All files are also saved locally in the `data/` folder.

---

### Step 8 — Stop the app

```bash
docker-compose down
```

Your data in `data/` is preserved.

---

## Troubleshooting

**"Cannot geocode city"**
→ The city name must match its OpenStreetMap entry exactly.
Add the province for small towns: `Bologna, Emilia-Romagna`.
Check at [nominatim.openstreetmap.org](https://nominatim.openstreetmap.org/).

**"OpenTopography API key missing"**
→ Check that `config/credentials.yml` exists and contains your key — not the placeholder text.

**"No Landsat scenes found"**
→ The warm-season window for this city may lack enough cloud-free scenes.
This is normal for cities with persistent summer cloud cover.
The tool only uses scenes with cloud cover ≤ 30%.

**App does not start**
→ Make sure Docker Desktop is running.
Try `docker-compose down`, then `docker-compose up --build`.

---

## How it works

```
┌─────────────────────────────────────────────────────────────────┐
│  0) User input     →  city name + local folder path             │
├─────────────────────────────────────────────────────────────────┤
│  1) Preliminary    →  load libraries, set bounding box,         │
│     operations        detect warm season via Köppen-Geiger      │
├─────────────────────────────────────────────────────────────────┤
│  2) Data download  →  Landsat 8-9 (ST + QA bands)              │
│                       Digital Elevation Model (SRTM)            │
│                       Urban & rural areas (OpenStreetMap)       │
├─────────────────────────────────────────────────────────────────┤
│  3) Pre-processing →  cloud masking, offset & scaling,          │
│                       LST conversion (°C), season mean          │
├─────────────────────────────────────────────────────────────────┤
│  4) Thermal        →  LST anomaly per 100 m elevation band      │
│     anomaly           (urban LST − rural LST reference)         │
├─────────────────────────────────────────────────────────────────┤
│  5) SUHII index    →  normalized index (0–1)                    │
│     + green access    distance from green urban areas map       │
└─────────────────────────────────────────────────────────────────┘
```

The tool segments the city into **100 m elevation bands** and computes
thermal anomalies within each band independently. This corrects for
altitude differences between urban and rural areas, making results
reliable for hilly and mountainous cities too.

---

## Scientific basis

### Heat island severity classes

| Class | LST anomaly vs rural |
|:------|:-------------------:|
| 🔵 Cool island | < 0 °C |
| ⚪ Neutral | 0–1 °C |
| 🟡 Weak | 1–2.5 °C |
| 🟠 Moderate | 2.5–4.5 °C |
| 🔴 Strong | 4.5–6.5 °C |
| 🟣 Extreme | > 6.5 °C |

Global average daytime SUHII across 419 cities: **1.5 ± 1.2 °C** (Peng et al. 2012).
Rule of thumb: LST anomaly ÷ 2 ≈ air temperature anomaly (Voogt & Oke 2003).

### Intervention priority index

```
Priority = 0.50 × norm(thermal anomaly)
         + 0.30 × norm(green access deficit)
         + 0.20 × urban mask
```

Weights follow Maragkogiannis et al. (2024) and Morabito et al. (2015, Sci Rep).
Adjustable in `R/functions/fn_outputs.R`.

### 3-30-300 rule

The green area distance layer implements the 300 m accessibility component
of the 3-30-300 rule (Konijnendijk 2022, J. For. Res. 34:821–830).

---

## Performance

Tested on Windows 11 Pro — 32 GB RAM, AMD Ryzen 7 2700X 3.70 GHz — across 40 cities worldwide.

| Metric | Average | Range |
|:-------|:-------:|:-----:|
| ⏱️ Total processing time | ~11 min | 4 min – 2 h |
| 💾 RAM usage | ~17 GB | up to ~27 GB |
| 🗺️ Area processed | ~2 160 km² | varies widely |

Most of the time is spent on downloads, not computation:

```
OSM download      ████████████████░░░░  ~4.6 min
Landsat download  ████████████████░░░░  ~4.6 min
DEM download      █░░░░░░░░░░░░░░░░░░░  ~0.3 min
LST processing    ██░░░░░░░░░░░░░░░░░░  ~0.5 min
SUHII calculation ████░░░░░░░░░░░░░░░░  ~1.3 min
Other             ░░░░░░░░░░░░░░░░░░░░  < 0.1 min
```

Large cities with extensive OSM data (e.g. Moscow) can reach ~120 min.
Download time is not simply proportional to city area — it depends on how
OpenStreetMap maps the area (aggregated polygons vs individual building footprints).

---

## Disclaimer

All outputs are based on the associated peer-reviewed publication.
Any use — for analysis, modelling, visualisation, or integration into other
projects — must cite the original paper:

> Richiardi, C., Caroscio, L., Crescini, E., De Marchi, M., De Pieri, G. M.,
> Ceresi, C., Baldo, F., Francobaldi, M., & Pappalardo, S. E. (2025).
> A global downstream approach to mapping surface urban heat islands using
> open data and collaborative technology.
> *Sustainable Geosciences: People, Planet and Prosperity*, 100006.
> [https://doi.org/10.1016/j.susgeo.2025.100006](https://doi.org/10.1016/j.susgeo.2025.100006)

---

## Project

Released under **GNU General Public License v3.0 (GPL 3.0)**.
Aligns with **SDG 11** (Sustainable Cities) and **SDG 17** (Partnerships for the Goals).

All code, data processing steps, and documentation are openly shared to
facilitate collaboration across research institutions, policy sectors, and
geographic regions.

---

## 💬 Share your feedback

We would love to hear how you are using this tool.

👉 [Fill out the feedback form](https://docs.google.com/forms/d/e/1FAIpQLScuYIyojP9iiTP3vjk2wFNVpeEuBwITrGmT-Cp-hU-JH-i7mw/viewform?usp=sf_link)

Want to contribute with code, ideas, or data? Open an issue or submit a pull request.

---

## Acknowledgements

Developed by **[Officina SCIFT](https://municipiozero.it/scift/)** —
Science, Craft, Innovation, Future, Technology.

🌐 [municipiozero.it/scift](https://municipiozero.it/scift/) · 
📷 [@scift_officina](https://www.instagram.com/scift_officina/) · 
✉️ sciftofficina@protonmail.com

---
---

# 🌡️ Mappatura SUHII

> **Mappa le isole di calore urbane in qualsiasi città del mondo — con soli dati aperti e gratuiti.**

`(Versione italiana)`

<p align="center">
  <img src="shiny/www/scift.jpg" height="80" alt="Logo Officina SCIFT"/>
</p>

---

## Cosa fa?

Produce automaticamente mappe di **Surface Urban Heat Island Intensity (SUHII)** per qualsiasi città — senza bisogno di competenze satellitari.

```
Scrivi il nome di una città  →  lo strumento fa tutto  →  ottieni mappe + report
```

Usa tre fonti di dati gratuite — nessun account necessario tranne una chiave API gratuita:

| Dato | Fonte | Account? |
|:-----|:------|:--------:|
| 🛰️ Immagini termiche satellitari | Landsat C2 L2 via Microsoft Planetary Computer | ✅ No |
| 🗺️ Uso del suolo e aree urbane | OpenStreetMap via Overpass API | ✅ No |
| ⛰️ Quota altimetrica | SRTM GL1 DEM via OpenTopography | ⚠️ Chiave gratuita necessaria |

> **LST ≠ temperatura dell'aria.**
> Lo strumento misura la **Land Surface Temperature**: quanto si scaldano le superfici (asfalto, tetti, suolo) viste dallo spazio — non la temperatura percepita all'esterno.

---

## Cosa ottieni

Per ogni città, i file vengono salvati in `data/<città>/Output/`:

| File | Cosa mostra |
|:-----|:-----------|
| `warm_<anno>_LST_MEAN.tif` | Temperatura superficiale media (°C) |
| `warm_<anno>_thermal_anomaly.tif` | Quanto l'urbano è più caldo del rurale (°C) |
| `warm_<anno>_SUHI.tif` | Indice di intensità dell'isola di calore (0–1) |
| `warm_<anno>_anomaly_classified.tif` | Mappa di severità a 6 classi |
| `warm_<anno>_priority_map.tif` | Dove intervenire prima (0–1) |
| `warm_<anno>_distance_green_areas.tif` | Distanza dalle aree verdi (m) |
| `warm_<anno>_anomaly_classified.geojson` | Export vettoriale GIS |
| `warm_<anno>_priority_map.geojson` | Export vettoriale GIS |
| `warm_<anno>_city_stats.csv` | Statistiche di sintesi |
| `<città>_warm_<anno>_report.html` | ✨ Report HTML interattivo completo |

---

## Come iniziare

### Cosa ti serve

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) — tutto qui. Nessun R, nessun Python, nessun pacchetto da installare manualmente.
- Una [chiave API OpenTopography](https://opentopography.org/developers) gratuita (ci vogliono 2 minuti).

---

### Passo 1 — Scarica il progetto

```bash
git clone https://github.com/Officina-SCIFT/SUHII_mapping.git
cd SUHII_mapping
```

Oppure scarica lo ZIP da GitHub ed estrailo.

---

### Passo 2 — Ottieni la chiave API gratuita

1. Vai su [opentopography.org/developers](https://opentopography.org/developers)
2. Registrati (gratuito, 2 minuti)
3. Copia la chiave API dalla pagina del tuo profilo

---

### Passo 3 — Inserisci la chiave nel progetto

```bash
cp config/credentials.yml.example config/credentials.yml
```

Apri `config/credentials.yml` con un editor di testo e sostituisci il placeholder:

```yaml
opentopography:
  api_key: "incolla-la-tua-chiave-qui"
```



---

### Passo 4 — Avvia il container

```bash
docker-compose up --build
```

> ⏳ **Il primo avvio richiede 10–15 minuti** — succede solo la prima volta.
> Docker sta scaricando R, Quarto e tutti i pacchetti necessari (~1 GB).
> Nel terminale scorre un lungo flusso di messaggi di installazione: è normale, non è un errore.
> **Non chiudere il terminale.**
>
> Gli avvii successivi richiedono meno di 30 secondi.

Quando vedi questa riga nel terminale, l'app è pronta:

```
suhii_app | [INFO] Starting listener on 0.0.0.0:3838
```

---

### Passo 5 — Apri l'app

👉 **[http://localhost:3838/suhii](http://localhost:3838/suhii)**

---

### Passo 6 — Esegui un'analisi

1. Scrivi il **nome della città** (usa il nome come appare in OpenStreetMap)
   → Per comuni piccoli aggiungi la provincia: `Bologna, Emilia-Romagna`
2. Clicca **Run analysis**
3. Segui il log di avanzamento nella barra laterale sinistra

> ☕ **Vai a farti un caffè — ci vogliono alcuni minuti.**
>
> Un'analisi tipica richiede **5–20 minuti** a seconda della dimensione della città.
> Non è una pagina che si carica: lo strumento sta scaricando immagini satellitari,
> elaborandole e calcolando le mappe termiche da zero.
> Il log di avanzamento ti aggiorna in tempo reale.
> Le città più grandi (es. Mosca) possono richiedere fino a ~2 ore.

---

### Passo 7 — Esplora i risultati

| Scheda | Cosa trovi |
|:-------|:----------|
| **Maps** | Quattro mappe Leaflet interattive |
| **Charts** | Distribuzione classi SUHII, confronto urbano/rurale |
| **Report** | Report HTML illustrato completo |
| **Downloads** | Pulsanti di download per ogni file di output |

Tutti i file sono salvati anche nella cartella `data/` sul tuo computer.

---

### Passo 8 — Ferma l'app

```bash
docker-compose down
```

I dati nella cartella `data/` vengono conservati.

---

## Risoluzione dei problemi

**"Cannot geocode city"**
→ Il nome della città deve corrispondere esattamente alla voce in OpenStreetMap.
Per comuni piccoli aggiungi la provincia: `Bologna, Emilia-Romagna`.
Verifica su [nominatim.openstreetmap.org](https://nominatim.openstreetmap.org/).

**"OpenTopography API key missing"**
→ Controlla che il file `config/credentials.yml` esista e contenga la tua chiave — non il testo placeholder.

**"No Landsat scenes found"**
→ La finestra stagionale calda di questa città potrebbe non avere abbastanza scene prive di nuvole.
È normale per città con copertura nuvolosa persistente in estate.
Lo strumento usa solo scene con cloud cover ≤ 30%.

**L'app non si avvia**
→ Verifica che Docker Desktop sia in esecuzione.
Prova `docker-compose down` e poi `docker-compose up --build`.

---

## Come funziona

```
┌─────────────────────────────────────────────────────────────────┐
│  0) Input utente   →  nome città + cartella di lavoro           │
├─────────────────────────────────────────────────────────────────┤
│  1) Operazioni     →  carica librerie, bounding box,            │
│     preliminari       rileva stagione calda via Köppen-Geiger   │
├─────────────────────────────────────────────────────────────────┤
│  2) Download dati  →  Landsat 8-9 (bande ST + QA)              │
│                       Modello digitale del terreno (SRTM)       │
│                       Aree urbane e rurali (OpenStreetMap)      │
├─────────────────────────────────────────────────────────────────┤
│  3) Pre-processing →  mascheratura nuvole, scaling,             │
│                       conversione LST (°C), media stagionale    │
├─────────────────────────────────────────────────────────────────┤
│  4) Anomalia       →  LST anomaly per fascia altimetrica 100 m  │
│     termica           (LST urbana − riferimento rurale)         │
├─────────────────────────────────────────────────────────────────┤
│  5) Indice SUHII   →  indice normalizzato (0–1)                 │
│     + verde           mappa distanza dalle aree verdi           │
└─────────────────────────────────────────────────────────────────┘
```

Lo strumento divide la città in **fasce altimetriche da 100 m** e calcola le
anomalie termiche indipendentemente per ciascuna fascia. Questo corregge le
differenze di quota tra aree urbane e rurali, rendendo i risultati affidabili
anche per città collinari e montane.

---

## Basi scientifiche

### Classi di severità dell'isola di calore

| Classe | Anomalia LST rispetto al rurale |
|:-------|:-------------------------------:|
| 🔵 Isola fresca | < 0 °C |
| ⚪ Neutrale | 0–1 °C |
| 🟡 Debole | 1–2,5 °C |
| 🟠 Moderata | 2,5–4,5 °C |
| 🔴 Forte | 4,5–6,5 °C |
| 🟣 Estrema | > 6,5 °C |

Media globale diurna su 419 città: **1,5 ± 1,2 °C** (Peng et al. 2012).
Regola empirica: anomalia LST ÷ 2 ≈ anomalia temperatura dell'aria (Voogt & Oke 2003).

### Indice di priorità di intervento

```
Priorità = 0,50 × norm(anomalia termica)
          + 0,30 × norm(deficit accesso al verde)
          + 0,20 × maschera urbana
```

Pesi da Maragkogiannis et al. (2024) e Morabito et al. (2015, Sci Rep).
Modificabili in `R/functions/fn_outputs.R`.

### Regola 3-30-300

Lo strato di distanza dal verde implementa la componente dei 300 m di accessibilità
della regola 3-30-300 (Konijnendijk 2022, J. For. Res. 34:821–830).

---

## Performance

Testato su Windows 11 Pro — 32 GB RAM, AMD Ryzen 7 2700X 3,70 GHz — su 40 città nel mondo.

| Metrica | Media | Range |
|:--------|:-----:|:-----:|
| ⏱️ Tempo totale di elaborazione | ~11 min | 4 min – 2 h |
| 💾 Utilizzo RAM | ~17 GB | fino a ~27 GB |
| 🗺️ Area processata | ~2 160 km² | molto variabile |

La maggior parte del tempo è impiegata nei download, non nel calcolo:

```
Download OSM      ████████████████░░░░  ~4,6 min
Download Landsat  ████████████████░░░░  ~4,6 min
Download DEM      █░░░░░░░░░░░░░░░░░░░  ~0,3 min
Elaborazione LST  ██░░░░░░░░░░░░░░░░░░  ~0,5 min
Calcolo SUHII     ████░░░░░░░░░░░░░░░░  ~1,3 min
Altro             ░░░░░░░░░░░░░░░░░░░░  < 0,1 min
```

Le città più grandi con molti dati OSM (es. Mosca) possono raggiungere ~120 min.
Il tempo di download non è semplicemente proporzionale all'area — dipende da come
OpenStreetMap mappa la zona (poligoni aggregati vs singoli edifici).

---

## Disclaimer

Tutti gli output si basano sulla pubblicazione scientifica associata.
Qualsiasi utilizzo — per analisi, modellazioni, visualizzazioni o integrazione
in altri progetti — deve includere la citazione del lavoro originale:

> Richiardi, C., Caroscio, L., Crescini, E., De Marchi, M., De Pieri, G. M.,
> Ceresi, C., Baldo, F., Francobaldi, M., & Pappalardo, S. E. (2025).
> A global downstream approach to mapping surface urban heat islands using
> open data and collaborative technology.
> *Sustainable Geosciences: People, Planet and Prosperity*, 100006.
> [https://doi.org/10.1016/j.susgeo.2025.100006](https://doi.org/10.1016/j.susgeo.2025.100006)

---

## Progetto

Rilasciato sotto licenza **GNU General Public License v3.0 (GPL 3.0)**.
Si allinea con **SDG 11** (Città sostenibili) e **SDG 17** (Partnership per gli obiettivi).

Tutto il codice, i passaggi di elaborazione e la documentazione sono condivisi
pubblicamente per facilitare la collaborazione tra istituzioni di ricerca,
settori politici e regioni geografiche.

---

## 💬 Condividi il tuo feedback

Ci piacerebbe sapere come stai utilizzando questo strumento.

👉 [Compila il modulo di feedback](https://docs.google.com/forms/d/e/1FAIpQLScuYIyojP9iiTP3vjk2wFNVpeEuBwITrGmT-Cp-hU-JH-i7mw/viewform?usp=sf_link)

Vuoi contribuire con codice, idee o dati? Apri una issue o invia una pull request.

---

## Ringraziamenti

Sviluppato da **[Officina SCIFT](https://municipiozero.it/scift/)** —
Science, Craft, Innovation, Future, Technology.

🌐 [municipiozero.it/scift](https://municipiozero.it/scift/) · 
📷 [@scift_officina](https://www.instagram.com/scift_officina/) · 
✉️ sciftofficina@protonmail.com
