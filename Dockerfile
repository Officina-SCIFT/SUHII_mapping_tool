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
# Build:  docker build -t suhii .
# Run:    docker-compose up
# =============================================================================

FROM rocker/shiny:4.4.0

# ── System dependencies ───────────────────────────────────────────────────────
# gdal, proj, geos   → terra / sf
# libudunits2        → units (sf dependency)
# libssl, libcurl    → httr / rstac
# pandoc             → quarto / rmarkdown
# wget, curl         → quarto installer
RUN apt-get update && apt-get install -y --no-install-recommends \
    gdal-bin \
    libgdal-dev \
    libproj-dev \
    libgeos-dev \
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

# ── Quarto ────────────────────────────────────────────────────────────────────
# Install the latest Quarto CLI (needed for render_report())
ARG QUARTO_VERSION=1.5.57
RUN wget -q "https://github.com/quarto-dev/quarto-cli/releases/download/v${QUARTO_VERSION}/quarto-${QUARTO_VERSION}-linux-amd64.deb" \
    -O /tmp/quarto.deb \
    && dpkg -i /tmp/quarto.deb \
    && rm /tmp/quarto.deb

# ── R packages ────────────────────────────────────────────────────────────────
# Install all packages at build time so the container starts instantly.
# Uses Posit Package Manager (P3M) for fast binary installs on Linux.
RUN R -e "\
options(repos = c(P3M = 'https://packagemanager.posit.co/cran/__linux__/jammy/latest')); \
pkgs <- c( \
  'terra', 'tidyterra', 'sf', 'osmdata', 'rstac', 'elevatr', \
  'dplyr', 'purrr', 'tidyr', 'tibble', 'scales', \
  'shiny', 'shinyWidgets', 'bslib', 'leaflet', 'leaflet.extras', \
  'ggplot2', 'plotly', 'colorRamps', 'colorspace', \
  'quarto', 'knitr', 'kableExtra', \
  'lubridate', 'httr', 'kgc', \
  'jsonlite', 'yaml', 'cli', \
  'sp', 'sfdep', 'spdep' \
); \
install.packages(pkgs, dependencies = TRUE) \
"

# ── App files ─────────────────────────────────────────────────────────────────
# Copy the entire project into the Shiny Server app directory
COPY . /srv/shiny-server/suhii/

# Set permissions
RUN chown -R shiny:shiny /srv/shiny-server/suhii/ \
    && chmod -R 755 /srv/shiny-server/suhii/

# ── Data volume mount point ───────────────────────────────────────────────────
# Output data is written here (mounted as a volume in docker-compose)
RUN mkdir -p /data && chown -R shiny:shiny /data

# ── Shiny Server config ───────────────────────────────────────────────────────
COPY shiny-server.conf /etc/shiny-server/shiny-server.conf

EXPOSE 3838

CMD ["/usr/bin/shiny-server"]
