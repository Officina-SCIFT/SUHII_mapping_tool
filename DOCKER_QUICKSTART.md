# SUHII Mapping Tool — Quick Start Guide

> **No R, no RStudio, no installation required.**
> Everything runs inside Docker — just open your browser.

---

## What you need

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed
  (free, available for Windows, Mac, Linux)
- A free [OpenTopography API key](https://opentopography.org/developers)
  (takes 2 minutes to register)
- An internet connection

That's it.

---

## Step 1 — Get your OpenTopography API key

1. Go to [opentopography.org](https://opentopography.org/developers)
2. Click **Register** and create a free account
3. Go to your profile → **API Key** → copy the key

---

## Step 2 — Set up your credentials

Open the `config/` folder and copy the example file:

```
config/
  credentials.yml.example   ← copy this
  credentials.yml           ← paste here, fill in your key
```

Edit `credentials.yml` and replace `YOUR_OPENTOPOGRAPHY_API_KEY` with your key:

```yaml
opentopography:
  api_key: "abc123yourkey"
```

**Never share this file or commit it to GitHub.**

---

## Step 3 — Start the app

Open a terminal in the project folder and run:

```bash
docker-compose up --build
```

> The **first run** downloads and installs everything (~10–15 minutes).
> Subsequent runs start in **under 30 seconds**.

When you see:

```
suhii_app  | [INFO] Starting listener on 0.0.0.0:3838
```

the app is ready.

---

## Step 4 — Open the app

Open your browser and go to:

**[http://localhost:3838/suhii](http://localhost:3838/suhii)**

You'll see the SUHII Mapping Tool interface.

---

## Step 5 — Run your analysis

1. **Enter a city name** — use the name as it appears on OpenStreetMap
   (e.g. `Florence`, `Bologna`, `Berlin`, `São Paulo`)
2. **Choose the season** — `warm` for summer heat island analysis
3. **Set cloud cover threshold** — 30% is a good default
4. **Click Run analysis**

The progress log on the left shows what's happening in real time.
A typical analysis takes **5–20 minutes** depending on the city size
and the number of available Landsat scenes.

---

## Step 6 — View and download results

When the analysis completes:

- **Maps tab**: interactive leaflet maps (LST, thermal anomaly, priority, green distance)
- **Charts tab**: class distribution bar chart, urban vs rural comparison
- **Report tab**: link to the full interactive HTML report
- **Downloads tab**: individual download buttons for each output file

All files are also saved in the `data/` folder on your computer.

---

## Stopping the app

```bash
docker-compose down
```

Your data is preserved in the `data/` folder.

---

## Understanding the outputs

| File | What it shows |
|:-----|:-------------|
| `warm_2024_LST_MEAN.tif` | Average daytime surface temperature (°C) |
| `warm_2024_thermal_anomaly.tif` | How much hotter each pixel is vs rural surroundings |
| `warm_2024_SUHI.tif` | Normalised heat island intensity (0–1) |
| `warm_2024_anomaly_classified.tif` | 6-class severity map |
| `warm_2024_priority_map.tif` | Where to plant trees / add green infrastructure |
| `warm_2024_distance_green_areas.tif` | Areas > 300 m from any park (3-30-300 rule) |
| `warm_2024_city_stats.csv` | All key numbers in a spreadsheet |
| `Florence_warm_2024_report.html` | Full illustrated report — open in any browser |

> **Important:** the thermal values are **Land Surface Temperature** differences,
> not air temperature. A 4°C LST anomaly corresponds roughly to ~2°C warmer air.
> See the "About" tab in the app for a full explanation.

---

## Troubleshooting

**"Cannot geocode city"**
→ Try the city's name in the local language, or as it appears on
[openstreetmap.org](https://www.openstreetmap.org/).

**"OpenTopography API key missing"**
→ Check that `config/credentials.yml` exists and contains your key (not the placeholder).

**"No Landsat scenes found"**
→ Try increasing the cloud cover threshold (e.g. 50%) or check the date window.
Some cities have fewer cloud-free scenes in certain seasons.

**App doesn't start**
→ Make sure Docker Desktop is running. Try `docker-compose down` then
`docker-compose up --build` again.

---

## Citation

If you use outputs from this tool, please cite:

> Richiardi, C., Caroscio, L., Crescini, E., De Marchi, M., De Pieri, G. M.,
> Ceresi, C., Baldo, F., Francobaldi, M., & Pappalardo, S. E. (2025).
> A global downstream approach to mapping surface urban heat islands using
> open data and collaborative technology.
> *Sustainable Geosciences: People, Planet and Prosperity*, 100006.
> https://doi.org/10.1016/j.susgeo.2025.100006
