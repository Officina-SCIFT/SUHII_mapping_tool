# Surface Urban Heat Island Intensity (SUHII) Mapping

`🇮🇹 Versione italiana sotto — Italian version below`

<p align="center">
  <img src="shiny/www/scift.jpg" height="80" alt="Officina SCIFT logo"/>
</p>

> An open, reproducible tool for mapping surface urban heat islands from satellite
> imagery and OpenStreetMap data — designed for researchers, urban planners,
> administrators, and non-technical users alike.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)

---

## What does this tool do?

This tool automatically maps the **Surface Urban Heat Island Intensity (SUHII)**
for any city in the world. It uses only free, open data:

- **Landsat Collection 2 Level 2** — satellite thermal imagery via
  [Microsoft Planetary Computer](https://planetarycomputer.microsoft.com/)
  (no account required)
- **OpenStreetMap** — land use and land cover data via Overpass API
- **SRTM GL1 DEM** — elevation data via
  [OpenTopography](https://opentopography.org/) (free API key required)

It produces **interactive maps, charts, and a self-contained HTML report**
suitable for sharing with non-technical audiences: city administrators,
journalists, citizens, and students.

> **Important — LST ≠ air temperature.**
> This tool measures **Land Surface Temperature (LST)**: the radiometric skin
> temperature of surfaces (asphalt, rooftops, soil) as seen from satellite.
> It is not the air temperature you feel outside. See the report and the
> app's About tab for a full explanation.

---

## Outputs

For each city the workflow saves the following to `/data/<city>/Output/`:

| File | Description |
|:-----|:------------|
| `warm_<year>_LST_MEAN.tif` | Mean seasonal Land Surface Temperature (°C) |
| `warm_<year>_thermal_anomaly.tif` | LST anomaly vs rural reference (°C) |
| `warm_<year>_SUHI.tif` | SUHII normalised index (0–1) |
| `warm_<year>_anomaly_classified.tif` | 6-class severity raster |
| `warm_<year>_priority_map.tif` | Intervention priority index (0–1) |
| `warm_<year>_distance_green_areas.tif` | Distance from green areas (m) |
| `warm_<year>_anomaly_classified.geojson` | Vector export for GIS |
| `warm_<year>_priority_map.geojson` | Vector export for GIS |
| `warm_<year>_city_stats.csv` | Summary statistics |
| `<city>_warm_<year>_report.html` | Full interactive HTML report |

---

## Quick start — Docker

**You only need to install [Docker Desktop](https://www.docker.com/products/docker-desktop/).**
No R, no RStudio, no other packages to install.

### Step 1 — Download the repository

```bash
git clone https://github.com/Officina-SCIFT/SUHII_mapping.git
cd SUHII_mapping
```

Or download the ZIP from GitHub and extract it.

### Step 2 — Get a free OpenTopography API key

1. Go to [opentopography.org](https://opentopography.org/developers)
2. Register (free, immediate)
3. Copy your API key from your profile page

### Step 3 — Add your credentials

Copy the example file and fill in your key:

```bash
cp config/credentials.yml.example config/credentials.yml
```

Open `config/credentials.yml` and replace the placeholder:

```yaml
opentopography:
  api_key: "your-key-here"
```

> **Never commit `credentials.yml` to a public repository.**
> It is already listed in `.gitignore`.

### Step 4 — Build and start

Open a terminal in the project folder and run:

```bash
docker-compose up --build
```

> ⏳ **The first build takes 10–15 minutes** — this is normal and only happens once.
> Docker is downloading R, Quarto, and all the required packages (~1 GB total).
> You will see a long stream of installation messages scrolling in the terminal:
> this is expected, not an error. **Do not close the terminal.**
>
> Once the build is complete, subsequent starts take under 30 seconds.

When you see:

```
suhii_app | [INFO] Starting listener on 0.0.0.0:3838
```

the app is ready.

### Step 5 — Open the app

Open your browser at:

**[http://localhost:3838/suhii](http://localhost:3838/suhii)**

### Step 6 — Run an analysis

1. Type a **city name** in the City field
   (use the name as it appears in OpenStreetMap;
   for small towns add the province: `Trofarello, Torino`)
2. Click **Run analysis**
3. Follow the progress log on the left sidebar

A typical analysis takes **5–20 minutes** depending on city size and the
number of available Landsat scenes.

### Step 7 — View and download results

When complete:

- **Maps** tab — four interactive Leaflet maps
- **Charts** tab — SUHII class distribution, urban vs rural LST comparison
- **Report** tab — link to the full illustrated HTML report
- **Downloads** tab — individual download buttons for every output file

All files are also saved in the `data/` folder on your machine.

### Step 8 — Stop the app

```bash
docker-compose down
```

Your data in `data/` is preserved.

---

## Scientific basis

### Classification thresholds (LST anomaly, °C)

The thermal anomaly raster is classified into six levels based on the
**LST difference** between each urban pixel and the rural reference mean:

| Class | LST anomaly | References |
|:------|:-----------:|:-----------|
| Cool island | < 0°C | Stewart & Oke (2012, BAMS) |
| Neutral | 0–1°C | Chen et al. (2019, IJERPH) |
| Weak | 1–2.5°C | Chen et al. (2019) |
| Moderate | 2.5–4.5°C | Chen et al. (2019) |
| Strong | 4.5–6.5°C | Chen et al. (2019) |
| Extreme | > 6.5°C | Chen et al. (2019) |

Global average daytime SUHII across 419 cities: **1.5 ± 1.2°C**
(Peng et al. 2012, Environ. Sci. Technol.).

Reminder: LST anomaly / 2 ≈ air temperature anomaly (Voogt & Oke 2003).

### Intervention priority index

```
Priority = 0.50 × norm(thermal anomaly)
         + 0.30 × norm(green access deficit)
         + 0.20 × urban mask
```

Urban pixels only. Weights follow Maragkogiannis et al. (2024) and
Morabito et al. (2015, Sci Rep). Weights are declared explicitly in
`R/functions/fn_outputs.R` and can be adjusted.

### 3-30-300 rule

The green area distance layer implements the 300 m accessibility component
of the 3-30-300 rule (Konijnendijk 2022, J. For. Res. 34:821–830).

---

## Troubleshooting

**"Cannot geocode city"**
→ Check the city name matches its OpenStreetMap entry.
For small municipalities add the province: `Trofarello, Torino`.
Verify at [nominatim.openstreetmap.org](https://nominatim.openstreetmap.org/).

**"OpenTopography API key missing"**
→ Check that `config/credentials.yml` exists and contains your key,
not the placeholder text.

**"No Landsat scenes found"**
→ The warm season window for the city may not have enough cloud-free scenes.
This is normal for cities with persistent cloud cover in summer.
The analysis uses all scenes with cloud cover ≤ 30%.

**App does not start**
→ Make sure Docker Desktop is running.
Try `docker-compose down` then `docker-compose up --build`.

---

## Disclaimer

All outputs are based on the associated peer-reviewed publication.
Any use of these data — for analysis, modelling, visualisation, or
incorporation into other projects — must include a citation to the
original paper:

> Richiardi, C., Caroscio, L., Crescini, E., De Marchi, M., De Pieri, G. M.,
> Ceresi, C., Baldo, F., Francobaldi, M., & Pappalardo, S. E. (2025).
> A global downstream approach to mapping surface urban heat islands using
> open data and collaborative technology.
> *Sustainable Geosciences: People, Planet and Prosperity*, 100006.
> [https://doi.org/10.1016/j.susgeo.2025.100006](https://doi.org/10.1016/j.susgeo.2025.100006)

Failure to cite the original publication may constitute a breach of
academic and professional standards.

---

## Project

The project aligns with SDG 17 (Partnerships for the Goals) by fostering
open, cross-sectoral collaboration through open science principles.
Released under the **GNU General Public License v3.0 (GPL 3.0)**.

All code, data processing steps, and documentation are openly shared to
facilitate collaboration across research institutions, policy sectors, and
geographic regions. The repository is a living resource that encourages
community contributions, interoperability between tools, and the co-creation
of robust environmental analyses supporting evidence-based decision-making.

---

## Feedback

We would love to hear how you are using the tool.

👉 [Fill out the feedback form](https://docs.google.com/forms/d/e/1FAIpQLScuYIyojP9iiTP3vjk2wFNVpeEuBwITrGmT-Cp-hU-JH-i7mw/viewform?usp=sf_link)

Filling it out means:
- 🛠️ telling us what works and what we can improve
- 🌍 contributing to an open and participatory knowledge process
- 💬 helping us shape the community space we are building

If you want to contribute — with code, ideas, feedback, or collaborations
— you are welcome. Open an issue or submit a pull request.

---

## Acknowledgements

Developed by **[Officina SCIFT](https://municipiozero.it/scift/)** —
Science, Craft, Innovation, Future, Technology.

- 🌐 [municipiozero.it/scift](https://municipiozero.it/scift/)
- 📷 [@scift_officina](https://www.instagram.com/scift_officina/)
- ✉️ sciftofficina@protonmail.com

---
---

# Mappatura dell'intensità delle isole di calore urbane superficiali (SUHII)

`(Versione italiana)`

<p align="center">
  <img src="shiny/www/scift.jpg" height="80" alt="Logo Officina SCIFT"/>
</p>

> Uno strumento aperto e riproducibile per mappare le isole di calore urbane
> superficiali a partire da immagini satellitari e dati OpenStreetMap —
> pensato per ricercatori, urbanisti, amministratori e utenti non tecnici.

---

## Cosa fa questo strumento?

Mappa automaticamente la **Surface Urban Heat Island Intensity (SUHII)** per
qualsiasi città nel mondo. Utilizza esclusivamente dati liberi e aperti:

- **Landsat Collection 2 Level 2** — immagini termiche satellitari via
  [Microsoft Planetary Computer](https://planetarycomputer.microsoft.com/)
  (nessun account richiesto)
- **OpenStreetMap** — uso del suolo via Overpass API
- **SRTM GL1 DEM** — dati di quota via
  [OpenTopography](https://opentopography.org/) (chiave API gratuita necessaria)

Produce **mappe interattive, grafici e un report HTML autocontenuto**
adatto a essere condiviso con pubblici non tecnici: amministratori locali,
giornalisti, cittadini e studenti.

> **Importante — LST ≠ temperatura dell'aria.**
> Lo strumento misura la **Land Surface Temperature (LST)**: la temperatura
> radiometrica delle superfici (asfalto, tetti, suolo) rilevata dal satellite.
> Non è la temperatura dell'aria percepita all'esterno. Consulta il report e
> la scheda "About" dell'app per una spiegazione completa.

---

## Output

Per ogni città il workflow salva i seguenti file in `/data/<città>/Output/`:

| File | Descrizione |
|:-----|:------------|
| `warm_<anno>_LST_MEAN.tif` | LST media stagionale (°C) |
| `warm_<anno>_thermal_anomaly.tif` | Anomalia LST rispetto all'area rurale (°C) |
| `warm_<anno>_SUHI.tif` | Indice SUHII normalizzato (0–1) |
| `warm_<anno>_anomaly_classified.tif` | Mappa di severità a 6 classi |
| `warm_<anno>_priority_map.tif` | Indice di priorità di intervento (0–1) |
| `warm_<anno>_distance_green_areas.tif` | Distanza dalle aree verdi (m) |
| `warm_<anno>_anomaly_classified.geojson` | Export vettoriale per GIS |
| `warm_<anno>_priority_map.geojson` | Export vettoriale per GIS |
| `warm_<anno>_city_stats.csv` | Statistiche di sintesi |
| `<città>_warm_<anno>_report.html` | Report HTML interattivo completo |

---

## Guida rapida — Docker (consigliato, nessuna installazione necessaria)

**Serve solo [Docker Desktop](https://www.docker.com/products/docker-desktop/).**
Nessun R, nessun RStudio, nessun pacchetto da installare.

### Passo 1 — Scarica la repository

```bash
git clone https://github.com/Officina-SCIFT/SUHII_mapping.git
cd SUHII_mapping
```

Oppure scarica lo ZIP da GitHub ed estrailo.

### Passo 2 — Ottieni una chiave API OpenTopography gratuita

1. Vai su [opentopography.org](https://opentopography.org/developers)
2. Registrati (gratuito, immediato)
3. Copia la tua API key dalla pagina del profilo

### Passo 3 — Inserisci le credenziali

Copia il file di esempio e inserisci la chiave:

```bash
cp config/credentials.yml.example config/credentials.yml
```

Apri `config/credentials.yml` con un editor di testo e sostituisci il placeholder:

```yaml
opentopography:
  api_key: "la-tua-chiave-qui"
```

> **Non committare mai `credentials.yml` su un repository pubblico.**
> È già incluso nel `.gitignore`.

### Passo 4 — Avvia il container

Apri un terminale nella cartella del progetto ed esegui:

```bash
docker-compose up --build
```

> ⏳ **Il primo avvio richiede 10–15 minuti** — è normale e succede solo la prima volta.
> Docker sta scaricando R, Quarto e tutti i pacchetti necessari (~1 GB in totale).
> Nel terminale vedrai scorrere un lungo flusso di messaggi di installazione:
> è tutto previsto, non è un errore. **Non chiudere il terminale.**
>
> Una volta completata la build, gli avvii successivi richiedono meno di 30 secondi.

Quando vedi:

```
suhii_app | [INFO] Starting listener on 0.0.0.0:3838
```

l'app è pronta.

### Passo 5 — Apri l'app nel browser

**[http://localhost:3838/suhii](http://localhost:3838/suhii)**

### Passo 6 — Esegui un'analisi

1. Scrivi il **nome della città** nel campo apposito
   (usa il nome come appare in OpenStreetMap;
   per comuni piccoli aggiungi la provincia: `Trofarello, Torino`)
2. Clicca **Run analysis**
3. Segui il log di avanzamento nella barra laterale sinistra

Un'analisi tipica richiede **5–20 minuti** a seconda della dimensione della
città e del numero di scene Landsat disponibili.

### Passo 7 — Visualizza e scarica i risultati

Al completamento:

- Scheda **Maps** — quattro mappe Leaflet interattive
- Scheda **Charts** — distribuzione delle classi SUHII, confronto urbano/rurale
- Scheda **Report** — link al report HTML illustrato completo
- Scheda **Downloads** — pulsanti di download per ogni file di output

Tutti i file sono salvati anche nella cartella `data/` sul tuo computer.

### Passo 8 — Ferma l'app

```bash
docker-compose down
```

I dati nella cartella `data/` vengono conservati.

---

## Risoluzione dei problemi

**"Cannot geocode city"**
→ Controlla che il nome della città corrisponda alla voce in OpenStreetMap.
Per comuni piccoli aggiungi la provincia: `Trofarello, Torino`.
Verifica su [nominatim.openstreetmap.org](https://nominatim.openstreetmap.org/).

**"OpenTopography API key missing"**
→ Controlla che il file `config/credentials.yml` esista e contenga la tua
chiave, non il testo placeholder.

**"No Landsat scenes found"**
→ La finestra stagionale calda della città analizzata potrebbe non avere
abbastanza scene prive di nuvole. È normale per città con copertura nuvolosa
persistente in estate. L'analisi usa tutte le scene con cloud cover ≤ 30%.

**L'app non si avvia**
→ Verifica che Docker Desktop sia in esecuzione.
Prova `docker-compose down` e poi `docker-compose up --build`.

---

## Disclaimer

Tutti gli output si basano sulla pubblicazione scientifica associata.
Qualsiasi utilizzo — per analisi, modellazioni, visualizzazioni o
integrazione in altri progetti — deve includere la citazione del lavoro
originale:

> Richiardi, C., Caroscio, L., Crescini, E., De Marchi, M., De Pieri, G. M.,
> Ceresi, C., Baldo, F., Francobaldi, M., & Pappalardo, S. E. (2025).
> A global downstream approach to mapping surface urban heat islands using
> open data and collaborative technology.
> *Sustainable Geosciences: People, Planet and Prosperity*, 100006.
> [https://doi.org/10.1016/j.susgeo.2025.100006](https://doi.org/10.1016/j.susgeo.2025.100006)

La mancata citazione della pubblicazione originale costituisce una violazione
degli standard accademici e professionali.

---

## Progetto

Il progetto si allinea con l'Obiettivo di Sviluppo Sostenibile n. 17
(Partnership per gli obiettivi), promuovendo la collaborazione aperta e
intersettoriale attraverso i principi della scienza aperta.
Rilasciato sotto licenza **GNU General Public License v3.0 (GPL 3.0)**.

Tutto il codice, i passaggi di elaborazione e la documentazione sono
condivisi pubblicamente per facilitare la collaborazione tra istituzioni
di ricerca, settori politici e regioni geografiche.
La repository è una risorsa viva che incoraggia i contributi della comunità,
l'interoperabilità tra strumenti e la co-creazione di analisi ambientali
robuste a supporto di decisioni basate su evidenze scientifiche.

---

## Feedback

Ci piacerebbe sapere come utilizzi lo strumento.

👉 [Compila il modulo di feedback](https://docs.google.com/forms/d/e/1FAIpQLScuYIyojP9iiTP3vjk2wFNVpeEuBwITrGmT-Cp-hU-JH-i7mw/viewform?usp=sf_link)

Compilarlo significa:
- 🛠️ indicarci cosa funziona e cosa possiamo migliorare
- 🌍 contribuire a un processo aperto e partecipato di conoscenza
- 💬 aiutarci a costruire lo spazio di dialogo che stiamo creando

Se vuoi contribuire — con codice, idee, feedback o collaborazioni —
sei benvenutə. Apri una issue o invia una pull request.

---

## Ringraziamenti

Sviluppato da **[Officina SCIFT](https://municipiozero.it/scift/)** —
Science, Craft, Innovation, Future, Technology.

- 🌐 [municipiozero.it/scift](https://municipiozero.it/scift/)
- 📷 [@scift_officina](https://www.instagram.com/scift_officina/)
- ✉️ sciftofficina@protonmail.com
