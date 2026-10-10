# =============================================================================
# Dockerfile — SUHII Mapping Tool
# =============================================================================
#
# Builds a single image containing:
#   - R 4.4 with all required packages pre-installed
#   - Quarto (for HTML report generation)
#   - Shiny Server (for the web UI)
#   - System libraries needed by terra, sf, osmextract
#
# --platform=linux/amd64 forces x86_64 emulation on Apple Silicon (M1/M2/M3)
# Macs via Rosetta 2, since the GDAL/PROJ/GEOS toolchain below is only
# verified against amd64. Slightly slower on Apple Silicon, but avoids
# arch-specific build failures.
FROM --platform=linux/amd64 rocker/shiny:4.4.0

# ── 1. System dependencies ─────────────────────────────────────────────────
# gdal, proj, geos   → terra / sf / lwgeom
# libudunits2        → units (sf dependency)
# libssl, libcurl    → httr / rstac
# pandoc             → quarto / rmarkdown
# wget, curl         → quarto installer
#
# GDAL/GEOS/PROJ dal repository Ubuntu 22.04 base (GDAL 3.4.1) sono troppo
# datati per compilare le release recenti di `terra` (richiede API introdotte
# in GDAL >= 3.6, es. GDALMDArray::AsClassicDataset a 3 argomenti).
# Si usa il PPA ubuntugis-unstable per versioni aggiornate, pinnate alle
# versioni esatte testate e confermate funzionanti (2026-07-16).
# NOTA: i PPA in genere non conservano versioni vecchie. Se questo build
# fallisce in futuro con "Version not found", il PPA ha rimosso queste
# versioni: verificare le versioni disponibili con
# `apt-cache madison gdal-bin` e aggiornare i pin qui sotto — e ricordarsi
# che un aggiornamento dei pin richiede SEMPRE di ricompilare il punto 4 per
# intero (sf + terra + lwgeom insieme), mai un pacchetto alla volta.
RUN apt-get update && apt-get install -y --no-install-recommends \
    software-properties-common \
    gnupg \
    && add-apt-repository -y ppa:ubuntugis/ubuntugis-unstable \
    && apt-get update && apt-get install -y --no-install-recommends \
    gdal-bin=3.8.4+dfsg-1~jammy0 \
    libgdal-dev=3.8.4+dfsg-1~jammy0 \
    libgdal34=3.8.4+dfsg-1~jammy0 \
    gdal-data=3.8.4+dfsg-1~jammy0 \
    libproj-dev=9.3.1-1~jammy0 \
    libproj25=9.3.1-1~jammy0 \
    proj-bin=9.3.1-1~jammy0 \
    proj-data=9.3.1-1~jammy0 \
    libgeos-dev=3.12.1-1~jammy0 \
    libgeos-c1v5=3.12.1-1~jammy0 \
    libgeos3.12.1=3.12.1-1~jammy0 \
    libudunits2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libxml2-dev \
    wget \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Verifica che le versioni siano state effettivamente aggiornate (fail-fast:
# se il build ripiega silenziosamente sui pacchetti jammy base, meglio saperlo qui).
RUN gdal-config --version && geos-config --version && pkg-config --modversion proj

# ── 2. Quarto ────────────────────────────────────────────────────────────
ARG QUARTO_VERSION=1.5.57
RUN wget -q "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
    -O /tmp/quarto.deb \
    && dpkg -i /tmp/quarto.deb \
    && rm /tmp/quarto.deb

# ── 3. Pacchetti R NON geospaziali — binari P3M (veloci, nessun link a ─────
#       GDAL/GEOS/PROJ, nessun rischio ABI)
# terra, sf e lwgeom NON compaiono qui: vengono installati SOLO al punto 4,
# da sorgente, tutti insieme. Se li vedi ricomparire in questa lista in una
# modifica futura, e' una regressione — rimuovili da qui.
RUN R -e "\
options(repos = c(P3M = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')); \
pkgs <- c( \
  'tidyterra', 'osmdata', 'rstac', 'elevatr', \
  'dplyr', 'purrr', 'tidyr', 'tibble', 'scales', \
  'shiny', 'shinyWidgets', 'bslib', 'leaflet', 'leaflet.extras', \
  'ggplot2', 'plotly', 'colorRamps', 'colorspace', \
  'quarto', 'knitr', 'kableExtra', \
  'lubridate', 'httr', 'curl', 'kgc', \
  'jsonlite', 'yaml', 'cli', 'maps', 'stringi', \
  'sp', 'sfdep', 'spdep' \
); \
install.packages(pkgs, dependencies = TRUE); \
missing <- pkgs[!pkgs %in% installed.packages()[,'Package']]; \
if (length(missing) > 0) stop('Pacchetti R non installati: ', paste(missing, collapse = ', ')) \
"

# ── 4. Stack geospaziale — SEMPRE i tre insieme, SEMPRE da sorgente ────────
# sf, terra e lwgeom vengono normalmente offerti come binari precompilati da
# P3M, linkati contro la libproj di jammy base. Il PPA ubuntugis-unstable ha
# sostituito PROJ con la 9.3.1: un binario precompilato agganciato alla
# libreria precedente smette di funzionare. Forziamo la ricompilazione da
# sorgente per allinearli alle librerie di sistema effettivamente presenti
# — i tre pacchetti in UN SOLO comando, non uno alla volta.
RUN R -e "\
install.packages(c('sf', 'terra', 'lwgeom'), type = 'source', repos = 'https://cran.r-project.org'); \
library(sf); library(terra); library(lwgeom); \
cat('Stack geospaziale OK\n') \
"

# ── 5. osmextract (OSM from Geofabrik extracts) — DOPO sf/terra/lwgeom ────────
# osmextract dipende da sf: installarlo al punto 3 farebbe scaricare un sf
# binario P3M agganciato alla libproj sbagliata (vedi nota al punto 4). Qui sf
# e' gia' installato da sorgente, quindi osmextract lo trova e non lo sostituisce.
# Segnala se GDAL non ha il driver OSM (necessario per leggere i .pbf): in quel
# caso il build NON fallisce, il tool ripiega su Overpass (vedi download_osm()).
RUN R -e "\
install.packages('osmextract', repos = 'https://cran.r-project.org'); \
library(osmextract); library(sf); \
if (!'OSM' %in% sf::st_drivers()\$name) cat('ATTENZIONE: GDAL senza driver OSM, Geofabrik non utilizzabile: il tool usera Overpass\n') else cat('osmextract OK, driver OSM presente\n') \
"

# ── App files ─────────────────────────────────────────────────────────────
# Copy the entire project into the Shiny Server app directory
COPY . /srv/shiny-server/suhii/

# Set permissions
RUN chown -R shiny:shiny /srv/shiny-server/suhii/ \
    && chmod -R 755 /srv/shiny-server/suhii/

# ── Data volume mount point ───────────────────────────────────────────────
# Output data is written here (mounted as a volume in docker-compose)
RUN mkdir -p /data && chown -R shiny:shiny /data

# ── Shiny Server config ───────────────────────────────────────────────────
COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

EXPOSE 3838

CMD ["/usr/bin/shiny-server"]
